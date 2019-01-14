package App::perlbrew;
use strict;
use warnings;
use 5.008;
our $VERSION = "0.85";
use Config;
BEGIN {
    # Special treat for Cwd to prevent it to be loaded from somewhere binary-incompatible with system perl.
    my @oldinc = @INC;

    @INC = (
        $Config{sitelibexp}."/".$Config{archname},
        $Config{sitelibexp},
        @Config{qw<vendorlibexp vendorarchexp archlibexp privlibexp>},
    );

    require Cwd;
    @INC = @oldinc;
}

use Getopt::Long ();
use CPAN::Perl::Releases;
use JSON::PP 'decode_json';
use Digest::SHA::PurePerl;

use App::Perlbrew::Path;
use App::Perlbrew::Path::Root;

sub min(@) {
    my $m = $_[0];
    for(@_) {
        $m = $_ if $_ < $m;
    }
    return $m;
}

sub uniq {
    my %seen; grep { !$seen{$_}++ } @_;
}



### global variables
# set $ENV{SHELL} to executable path of parent process (= shell) if it's missing
# (e.g. if this script was executed by a daemon started with "service xxx start")
# ref: https://github.com/gugod/App-perlbrew/pull/404
$ENV{SHELL} ||= App::Perlbrew::Path->new ("/proc", getppid, "exe")->readlink if -d "/proc";

local $SIG{__DIE__} = sub {
    my $message = shift;
    warn $message;
    exit(1);
};

our $CONFIG;
our $PERLBREW_ROOT;
our $PERLBREW_HOME;

my @flavors = ( { d_option => 'usethreads',
                  implies  => 'multi',
                  common   => 1,
                  opt      => 'thread|threads' }, # threads is for backward compatibility

                { d_option => 'usemultiplicity',
                  opt      => 'multi' },

                { d_option => 'uselongdouble',
                  common   => 1,
                  opt      => 'ld' },

                { d_option => 'use64bitint',
                  common   => 1,
                  opt      => '64int' },

                { d_option => 'use64bitall',
                  implies  => '64int',
                  opt      => '64all' },

                { d_option => 'DEBUGGING',
                  opt      => 'debug' },

                { d_option => 'cc=clang',
                  opt      => 'clang' },
              );

my %flavor;
my $flavor_ix = 0;
for (@flavors) {
    my ($name) = $_->{opt} =~ /([^|]+)/;
    $_->{name} = $name;
    $_->{ix} = ++$flavor_ix;
    $flavor{$name} = $_;
}
for (@flavors) {
    if (my $implies = $_->{implies}) {
        $flavor{$implies}{implied_by} = $_->{name};
    }
}

### functions

sub files_are_the_same {
    ## Check dev and inode num. Not useful on Win32.
    ## The for loop should always return false on Win32, as a result.

    my @files = @_;
    my @stats = map {[ stat($_) ]} @files;

    my $stats0 = join " ", @{$stats[0]}[0,1];
    for (@stats) {
        return 0 if ((! defined($_->[1])) || $_->[1] == 0);
        unless ($stats0 eq join(" ", $_->[0], $_->[1])) {
            return 0;
        }
    }
    return 1
}

{

    my %commands = (
        curl => {
            test     => '--version >/dev/null 2>&1',
            get      => '--silent --location --fail -o - "{url}"',
            download => '--silent --location --fail -o {output} "{url}"',
            order    => 1,

            # Exit code is 22 on 404s etc
            die_on_error => sub { die 'Page not retrieved; HTTP error code 400 or above.' if ($_[ 0 ] >> 8 == 22); },
        },
        wget => {
            test     => '--version >/dev/null 2>&1',
            get      => '--quiet -O - "{url}"',
            download => '--quiet -O {output} "{url}"',
            order    => 2,

            # Exit code is not 0 on error
            die_on_error => sub { die 'Page not retrieved: fetch failed.' if ($_[ 0 ]); },
        },
        fetch => {
            test     => '--version >/dev/null 2>&1',
            get      => '-o - "{url}"',
            download => '-o {output} "{url}"',
            order    => 3,

            # Exit code is 8 on 404s etc
            die_on_error => sub { die 'Server issued an error response.' if ($_[ 0 ] >> 8 == 8); },
        }
    );

    our $HTTP_USER_AGENT_PROGRAM;
    sub http_user_agent_program {
        $HTTP_USER_AGENT_PROGRAM ||= do {
            my $program;

            for my $p (sort {$commands{$a}{order}<=>$commands{$b}{order}} keys %commands) {
                my $code = system("$p $commands{$p}->{test}") >> 8;
                if ($code != 127) {
                    $program = $p;
                    last;
                }
            }

            unless ($program) {
                die "[ERROR] Cannot find a proper http user agent program. Please install curl or wget.\n";
            }

            $program;
        };

        die "[ERROR] Unrecognized http user agent program: $HTTP_USER_AGENT_PROGRAM. It can only be one of: ".join(",", keys %commands)."\n" unless $commands{$HTTP_USER_AGENT_PROGRAM};

        return $HTTP_USER_AGENT_PROGRAM;
    }

    sub http_user_agent_command {
        my ($purpose, $params) = @_;
        my $ua = http_user_agent_program;
        my $cmd = $ua . " " . $commands{ $ua }->{ $purpose };
        for (keys %$params) {
            # XXX: Need to shell escape parameter
            $cmd =~ s!{$_}!$params->{$_}!g;
        }
        return ($ua, $cmd) if wantarray;
        return $cmd;
    }

    sub http_download {
        my ($url, $path) = @_;

        if (-e $path) {
            die "ERROR: The download target < $path > already exists.\n";
        }

        my $partial = 0;
        local $SIG{TERM} = local $SIG{INT} = sub { $partial++ };


        my $download_command = http_user_agent_command(download => { url => $url, output => $path });

        my $status = system($download_command);
        if ($partial) {
            $path->unlink;
            return "ERROR: Interrupted.";
        }
        unless ($status == 0) {
            $path->unlink;
            return "ERROR: Failed to execute the command\n\n\t$download_command\n\nReason:\n\n\t$?";
        }
        return 0;
    }

    sub http_get {
        my ($url, $header, $cb) = @_;

        if (ref($header) eq 'CODE') {
            $cb = $header;
            $header = undef;
        }

        my ($program, $command) = http_user_agent_command(get => { url =>  $url });

        open my $fh, '-|', $command
            or die "open() pipe for '$command': $!";

        local $/;
        my $body = <$fh>;
        close $fh;

        # check if the download has failed and die automatically
        $commands{ $program }{ die_on_error }->($?);

        return $cb ? $cb->($body) : $body;
    }
}

sub perl_version_to_integer {
    my $version = shift;
    my @v = split(/[\.\-_]/, $version);
    return undef if @v < 2;
    if ($v[1] <= 5) {
        $v[2] ||= 0;
        $v[3] = 0;
    }
    else {
        $v[3] ||= $v[1] >= 6 ? 9 : 0;
        $v[3] =~ s/[^0-9]//g;
    }

    return $v[1]*1000000 + $v[2]*1000 + $v[3];
}

# straight copy of Wikipedia's "Levenshtein Distance"
sub editdist {
    my @a = split //, shift;
    my @b = split //, shift;

    # There is an extra row and column in the matrix. This is the
    # distance from the empty string to a substring of the target.
    my @d;
    $d[$_][0] = $_ for (0 .. @a);
    $d[0][$_] = $_ for (0 .. @b);

    for my $i (1 .. @a) {
        for my $j (1 .. @b) {
            $d[$i][$j] = ($a[$i-1] eq $b[$j-1] ? $d[$i-1][$j-1]
                : 1 + min($d[$i-1][$j], $d[$i][$j-1], $d[$i-1][$j-1]));
        }
    }

    return $d[@a][@b];
}

### methods

sub new {
    my($class, @argv) = @_;

    my %opt = (
        original_argv  => \@argv,
        args => [],
        yes   => 0,
        force => 0,
        quiet => 0,
        D => [],
        U => [],
        A => [],
        sitecustomize => '',
        destdir => '',
        noman => '',
        variation => '',
        both => [],
        append => '',
        reverse => 0,
        verbose => 0,
    );

    $opt{$_} = '' for keys %flavor;

    if (@argv) {
        # build a local @ARGV to allow us to use an older
        # Getopt::Long API in case we are building on an older system
        local (@ARGV) = @argv;

        Getopt::Long::Configure(
            'pass_through',
            'no_ignore_case',
            'bundling',
            'permute',          # default behaviour except 'exec'
        );

        $class->parse_cmdline(\%opt);

        $opt{args} = \@ARGV;

        # fix up the effect of 'bundling'
        foreach my $flags (@opt{qw(D U A)}) {
            foreach my $value (@{$flags}) {
                $value =~ s/^=//;
            }
        }
    }

    my $self = bless \%opt, $class;

	# Treat --root option same way as env variable PERLBREW_ROOT (with higher priority)
	$ENV{PERLBREW_ROOT} = $self->root ($opt{root})
		if $opt{root};

	$self->{builddir} = App::Perlbrew::Path->new ($self->{builddir})
		if $opt{builddir};

	# Ensure propagation of $PERLBREW_HOME and $PERLBREW_ROOT
	$self->root;
	$self->home;

    return $self;
}

sub parse_cmdline {
    my ($self, $params, @ext) = @_;

    my @f = map { $flavor{$_}{opt} || $_ } keys %flavor;

    return Getopt::Long::GetOptions(
        $params,

        'yes',
        'force|f',
        'reverse',
        'notest|n',
        'quiet|q',
        'verbose|v',
        'as=s',
        'append=s',
        'help|h',
        'version',
        'root=s',
        'switch',
        'all',
        'shell=s',
        'no-patchperl',

        "builddir=s",

        # options passed directly to Configure
        'D=s@',
        'U=s@',
        'A=s@',

        'j=i',
        # options that affect Configure and customize post-build
        'sitecustomize=s',
        'destdir=s',
        'noman',

        # flavors support
        'both|b=s@',
        'all-variations',
        'common-variations',
        @f,

        @ext
    )
}

sub root {
    my ($self, $new_root) = @_;

	$new_root ||= $PERLBREW_ROOT
		|| $ENV{PERLBREW_ROOT}
		|| App::Perlbrew::Path->new ($ENV{HOME}, "perl5", "perlbrew")->stringify
		unless $self->{root};

	$self->{root} = $PERLBREW_ROOT = $new_root
		if defined $new_root;

	$self->{root} = App::Perlbrew::Path::Root->new ($self->{root})
		unless ref $self->{root};

	$self->{root} = App::Perlbrew::Path::Root->new ($self->{root}->stringify)
		unless $self->{root}->isa ('App::Perlbrew::Path::Root');

    return $self->{root};
}

sub home {
    my ($self, $new_home) = @_;

	$new_home ||= $PERLBREW_HOME
		|| $ENV{PERLBREW_HOME}
		|| App::Perlbrew::Path->new ($ENV{HOME}, ".perlbrew")->stringify
		unless $self->{home};

	$self->{home} = $PERLBREW_HOME = $new_home
		if defined $new_home;

	$self->{home} = App::Perlbrew::Path->new ($self->{home})
		unless ref $self->{home};

    return $self->{home};
}

sub builddir {
	my ($self) = @_;

    return $self->{builddir} || $self->root->build;
}

sub current_perl {
    my ($self, $v) = @_;
    $self->{current_perl} = $v if $v;
    return $self->{current_perl} || $self->env('PERLBREW_PERL')  || '';
}

sub current_lib {
    my ($self, $v) = @_;
    $self->{current_lib} = $v if $v;
    return $self->{current_lib} || $self->env('PERLBREW_LIB')  || '';
}

sub current_shell_is_bashish {
    my ($self) = @_;
    if (($self->current_shell eq 'bash') or ($self->current_shell eq 'zsh')) {
        return 1;
    } else {
        return 0;
    }
}

sub current_shell {
    my ($self, $x) = @_;
    $self->{current_shell} = $x if $x;
    return $self->{current_shell} ||= do {
        my $shell_name = App::Perlbrew::Path->new ($self->{shell} || $self->env('SHELL'))->basename;
        $shell_name =~ s/\d+$//;
        $shell_name;
    };
}

sub current_env {
    my ($self) = @_;
    my $l = $self->current_lib;
    $l = "@" . $l if $l;
    return $self->current_perl . $l;
}

sub installed_perl_executable {
    my ($self, $name) = @_;
    die unless $name;

    my $executable = $self->root->perls ($name)->perl;
    return $executable if -e $executable;
    return "";
}

sub configure_args {
    my ($self, $name) = @_;

    my $perl_cmd = $self->installed_perl_executable($name);
    my $code = 'while(($_,$v)=each(%Config)){print"$_ $v" if /config_arg/}';

    my @output = split "\n" => $self->do_capture($perl_cmd, '-MConfig', '-wle', $code);

    my %arg;
    for(@output) {
        my ($k, $v) = split " ", $_, 2;
        $arg{$k} = $v;
    }

    if (wantarray) {
        return map { $arg{"config_arg$_"} } (1 .. $arg{config_argc})
    }

    return $arg{config_args}
}

sub cpan_mirror {
    my ($self) = @_;
    unless($self->{cpan_mirror}) {
        $self->{cpan_mirror} = $self->env("PERLBREW_CPAN_MIRROR") || "https://www.cpan.org";
        $self->{cpan_mirror} =~ s{/+$}{};
    }
    return $self->{cpan_mirror};
}

sub env {
    my ($self, $name) = @_;
    return $ENV{$name} if $name;
    return \%ENV;
}

sub is_shell_csh {
    my ($self) = @_;
    return 1 if $self->env('SHELL') =~ /(t?csh)/;
    return 0;
}

# Entry point method: handles all the arguments
# and dispatches to an appropriate internal
# method to execute the corresponding command.
sub run {
    my($self) = @_;
    $self->run_command($self->args);
}

sub args {
    my ($self) = @_;

    # keep 'force' and 'yes' coherent across commands
    $self->{force} = $self->{yes} = 1 if ($self->{force} || $self->{yes});

    return @{ $self->{args} };
}

sub commands {
    my ($self) = @_;

    my $package =  ref $self ? ref $self : $self;

    my @commands;
    my $symtable = do {
        no strict 'refs';
        \%{$package . '::'};
    };

    foreach my $sym (keys %$symtable) {
        if ($sym =~ /^run_command_/) {
            my $glob = $symtable->{$sym};
            if (ref($glob) eq 'CODE' || defined *$glob{CODE}) {
                # with perl >= 5.27 stash entry can points to a CV directly
                $sym =~ s/^run_command_//;
                $sym =~ s/_/-/g;
                push @commands, $sym;
            }
        }
    }

    return @commands;
}

sub find_similar_commands {
    my ($self, $command) = @_;
    my $SIMILAR_DISTANCE = 6;

    $command =~ s/_/-/g;

    my @commands = sort {
        $a->[1] <=> $b->[1]
    } map {
        my $d = editdist($_, $command);
        (($d < $SIMILAR_DISTANCE) ? [ $_, $d ] : ())
    } $self->commands;

    if (@commands) {
        my $best  = $commands[0][1];
        @commands = map { $_->[0] } grep { $_->[1] == $best } @commands;
    }

    return @commands;
}

# This method is called in the 'run' loop
# and executes every specific action depending
# on the type of command.
#
# The first argument to this method is a self reference,
# while the first "real" argument is the command to execute.
# Other parameters after the command to execute are
# considered as arguments for the command itself.
#
# In general the command is executed via a method named after the
# command itself and with the 'run_command' prefix. For instance
# the command 'exec' is handled by a method
# `run_command_exec`
#
# If no candidates can be found, an execption is thrown
# and a similar command is shown to the user.
sub run_command {
    my ($self, $x, @args) = @_;
    my $command = $x;

    if ($self->{version}) {
        $x = 'version';
    }
    elsif (!$x) {
        $x = 'help';
        @args = (0, $self->{help} ? 2 : 0);
    }
    elsif ($x eq 'help') {
        @args = (0, 2) unless @args;
    }

    my $s = $self->can("run_command_$x");
    unless ($s) {
        $x =~ y/-/_/;
        $s = $self->can("run_command_$x");
    }

    unless ($s) {
        my @commands = $self->find_similar_commands($x);

        if (@commands > 1) {
            @commands = map { '    ' . $_ } @commands;
            die "Unknown command: `$command`. Did you mean one of the following?\n" . join("\n", @commands) . "\n";
        } elsif (@commands == 1) {
            die "Unknown command: `$command`. Did you mean `$commands[0]`?\n";
        } else {
            die "Unknown command: `$command`. Typo?\n";
        }
    }

    $self->$s(@args);
}

sub run_command_version {
    my ($self) = @_;
    my $package = ref $self;
    my $version = $self->VERSION;
    print "$0  - $package/$version\n";
}

# Provides help information about a command.
# The idea is similar to the 'run_command' and 'run_command_$x' chain:
# this method dispatches to a 'run_command_help_$x' method
# if found in the class, otherwise it tries to extract the help
# documentation via the POD of the class itself using the
# section 'COMMAND: $x' with uppercase $x.
sub run_command_help {
    my ($self, $status, $verbose, $return_text) = @_;

    require Pod::Usage;

    if ($status && !defined($verbose)) {
        if ($self->can("run_command_help_${status}")) {
            $self->can("run_command_help_${status}")->($self);
        }
        else {
            my $out = "";
            open my $fh, ">", \$out;

            Pod::Usage::pod2usage(
                -exitval   => "NOEXIT",
                -verbose   => 99,
                -sections  => "COMMAND: " . uc($status),
                -output    => $fh,
                -noperldoc => 1
            );
            $out =~ s/\A[^\n]+\n//s;
            $out =~ s/^    //gm;

            if ($out =~ /\A\s*\Z/) {
                $out = "Cannot find documentation for '$status'\n\n";
            }

            return "\n$out" if ($return_text);
            print "\n$out";
            close $fh;
        }
    }
    else {
        Pod::Usage::pod2usage(
            -noperldoc => 1,
            -verbose => $verbose||0,
            -exitval => (defined $status ? $status : 1)
        );
    }
}

# introspection for compgen
my %comp_installed = (
    use    => 1,
    switch => 1,
);

sub run_command_compgen {
    my($self, $cur, @args) = @_;

    $cur = 0 unless defined($cur);

    # do `tail -f bashcomp.log` for debugging
    if ($self->env('PERLBREW_DEBUG_COMPLETION')) {
        open my $log, '>>', 'bashcomp.log';
        print $log "[$$] $cur of [@args]\n";
    }
    my $subcommand           = $args[1];
    my $subcommand_completed = ($cur >= 2);

    if (!$subcommand_completed) {
        $self->_compgen($subcommand, $self->commands);
    }
    else { # complete args of a subcommand
        if ($comp_installed{$subcommand}) {
            if ($cur <= 2) {
                my $part;
                if (defined($part = $args[2])) {
                    $part = qr/ \Q$part\E /xms;
                }
                $self->_compgen($part,
                    map{ $_->{name} } $self->installed_perls());
            }
        }
        elsif ($subcommand eq 'help') {
            if ($cur <= 2) {
                $self->_compgen($args[2], $self->commands());
            }
        }
        else {
            # TODO
        }
    }
}

sub _firstrcfile {
    my ($self) = @_;
    foreach my $path (@_) {
        return $path if -f App::Perlbrew::Path->new ($self->env('HOME'), $path);
    }
    return;
}

sub _compgen {
    my($self, $part, @reply) = @_;
    if (defined $part) {
        $part = qr/\A \Q$part\E /xms if ref($part) ne ref(qr//);
        @reply = grep { /$part/ } @reply;
    }
    foreach my $word(@reply) {
        print $word, "\n";
    }
}

# Internal utility function.
# Given a specific perl version, e.g., perl-5.27.4
# returns a string with a formatted version number such
# as 05027004. Such string can be used as a number
# in order to make either a string comparison
# or a numeric comparison.
#
# In the case of cperl the major number is added by 6
# so that it would match the project claim of being
# Perl 5+6 = 11. The final result is then
# multiplied by a negative factor (-1) in order
# to make cperl being "less" in the ordered list
# than a normal Perl installation.
#
# The returned string is made by four pieces of two digits each:
# MMmmppbb
# where:
# MM is the major Perl version (e.g., 5 -> 05)
# mm is the minor Perl version (e.g. 27 -> 27)
# pp is the patch level (e.g., 4 -> 04)
# bb is the blead flag: it is 00 for a "normal" release, or 01 for a blead one
sub comparable_perl_version {
    my ($self, $perl_version)   = @_;
    my ($is_cperl, $is_blead)   = (0, 0);
    my ($major, $minor, $patch) = (0, 0, 0);
    if ($perl_version =~ /^(?:(c?perl)-?)?(\d)\.(\d+).(\d+).*/) {
        $is_cperl = $1 && ($1 eq 'cperl');
        $major    = $2 + ($is_cperl ? 6 : 0);               # major version
        $minor    = $3;                                     # minor version
        $patch    = $4;                                     # patch level

    }
    elsif ($perl_version =~ /^(?:(c?perl)-?)?-?(blead)$/) {
        # in the case of a blead release use a fake high number
        # to assume it is the "latest" release number available
        $is_cperl = $1 && ($1 eq 'cperl');
        $is_blead = $2 && ($2 eq 'blead');
        ($major, $minor, $patch) = (5, 99, 99);
    }

    return ($is_cperl ? -1 : 1)
        * sprintf('%02d%02d%02d%02d',
                  $major + ($is_cperl ? 6 : 0),              # major version
                  $minor,                                    # minor version
                  $patch,                                    # patch level
                  $is_blead);                                # blead
}

# Internal method.
# Performs a comparable sort of the perl versions specified as
# list.
sub sort_perl_versions {
    my ($self, @perls) = @_;

    return map { $_->[ 0 ] }
    sort { (  $self->{reverse}
            ? $a->[ 1 ] <=> $b->[ 1 ]
            : $b->[ 1 ] <=> $a->[ 1 ] ) }
           map { [ $_, $self->comparable_perl_version($_) ] }
           @perls;
}

sub run_command_available {
    my ($self) = @_;
    my $perls     = $self->available_perls_with_urls(@_);
    my @installed = $self->installed_perls(@_);
    my $is_verbose = $self->{verbose};

    # sort the keys of Perl installation (Randal to the rescue!)
    my @sorted_perls = $self->sort_perl_versions(keys %$perls);

    for my $available (@sorted_perls) {
        my $url = $perls->{$available};
        my $ctime;

        for my $installed (@installed) {
            my $name = $installed->{name};
            my $cur  = $installed->{is_current};
            if ($available eq $installed->{name}) {
                $ctime = $installed->{ctime};
                last;
            }
        }

        printf "\n%1s %12s  %s %s",
            $ctime ? 'i' : '',
            $available,
            ( $is_verbose
              ? $ctime ? "INSTALLED on $ctime via"  : 'available from '
              : ''),
            ( $is_verbose ? "<$url>" : '' ) ;
    }

    print "\n";

    return @sorted_perls;
}

sub available_perls {
    my ($self) = @_;
    my $perls    = $self->available_perls_with_urls;
    return $self->sort_perl_versions(keys %$perls);
}

sub available_perls_with_urls {
    my ($self, $dist, $opts) = @_;
    my $perls = {};
    my @perllist;

    my $url = $self->{all}  ? "https://www.cpan.org/src/5.0/"
                            : "https://www.cpan.org/src/README.html" ;
    my $html = http_get($url, undef, undef);
    unless ($html) {
        die "\nERROR: Unable to retrieve the list of perls.\n\n";
    }
    for (split "\n", $html) {
        my ($current_perl, $current_url);
        if ($self->{all}) {
            ($current_perl, $current_url) = ($2, $1) if m|<a href="(perl.*?\.tar\.gz)">\s*([^\s]+?)\s*</a>|;
        }
        else {
            ($current_perl, $current_url ) = ($2, $1) if m|<td><a href="(http(?:s?)://www.cpan.org/src/.+?)">\s*([^\s]+?)\s*</a></td>|;
        }

        # if we have a $current_perl add it to the available hash of perls
        if ($current_perl) {
            $current_perl =~ s/\.tar\.gz//;
            push @perllist, [ $current_perl, $current_url ];
            $perls->{$current_perl} = $current_url;
        }
    }

    # we got impatient waiting for cpan.org to get updated to show 5.28...
    # So, we also fetch from metacpan for anything that looks perlish,
    # and we do our own processing to filter out the development
    # releases and minor versions when needed (using
    # filter_perl_available)
    $url = 'https://fastapi.metacpan.org/v1/release/versions/perl';
    $html = http_get($url, undef, undef);
    unless ($html) {
        $html = '';
        warn "\nERROR: Unable to retrieve list of perls from Metacpan.\n\n";
    }
    while ($html =~ m{"(http(?:s?)://cpan\.metacpan\.org/[^"]+/(perl-5\.[0-9]+\.[0-9]+(?:-[A-Z0-9]+)?)\.tar\.(?:bz2|gz))"}g) {
        my ($current_perl, $current_url) = ($2, $1);

        push @perllist, [ $current_perl, $current_url ];
    }
    foreach my $perl ($self->filter_perl_available(\@perllist)) {
        # We only want to add a Metacpan link if the www.cpan.org link
        # doesn't exist, and this assures that we do that properly.
        if (!exists($perls->{ $perl->[0] })) {
            $perls->{ $perl->[0] } = $perl->[1];
        }
    }

    # cperl releases: https://github.com/perl11/cperl/tags
    my $cperl_remote           = 'https://github.com';
    my $url_cperl_release_list = $cperl_remote . '/perl11/cperl/tags';

    $html = http_get($url_cperl_release_list);
    if ($html) {
        while ($html =~ m{href="(/perl11/cperl/archive/cperl-(5.+?)\.tar\.gz)"}xg) {
            $perls->{ "cperl-$2" } = $cperl_remote . $1;
        }
    } else {
        if ($self->{verbose}) {
            warn "\nWARN: Unable to retrieve the list of cperl releases.\n\n";
        }
    }

    return $perls;
}

# $perllist is an arrayref of arrayrefs.  The inner arrayrefs are of the
# format: [ <perl_name>, <perl_url> ]
#   perl_name = something like perl-5.28.0
#   perl_url  = URL the Perl is available from.
#
# If $self->{all} is true, this just returns a list of the contents of
# the list referenced by $perllist
#
# Otherwise, this looks for even middle numbers in the version and no
# suffix (like -RC1) following the URL, and returns the list of
# arrayrefs that so match
#
# If any "newest" Perl has a
sub filter_perl_available {
    my ($self, $perllist) = @_;

    if ($self->{all}) { return @$perllist; }

    my %max_release;
    foreach my $perl (@$perllist) {
        my $ver = $perl->[0];
        if ($ver !~ m/^perl-5\.[0-9]*[02468]\.[0-9]+$/) { next; } # most likely TRIAL or RC, or a DEV release

        my ($release_line, $minor) = $ver =~ m/^perl-5\.([0-9]+)\.([0-9]+)/;
        if (exists $max_release{$release_line}) {
            if ($max_release{$release_line}->[0] > $minor) { next; } # We have a newer release
        }

        $max_release{$release_line} = [ $minor, $perl ];
    }

    return map { $_->[1] } values %max_release;
}

sub perl_release {
    my ($self, $version) = @_;
    my $mirror = $self->cpan_mirror();

    # try CPAN::Perl::Releases
    my $tarballs = CPAN::Perl::Releases::perl_tarballs($version);

    my $x = (values %$tarballs)[0];
    if ($x) {
        my $dist_tarball = (split("/", $x))[-1];
        my $dist_tarball_url = "$mirror/authors/id/$x";
        return ($dist_tarball, $dist_tarball_url);
    }

    # try src/5.0 symlinks, either perl-5.X or perl5.X; favor .tar.bz2 over .tar.gz
    my $index = http_get("https://www.cpan.org/src/5.0/");
    if ($index) {
        for my $prefix ("perl-", "perl") {
            for my $suffix (".tar.bz2", ".tar.gz") {
                my $dist_tarball = "$prefix$version$suffix";
                my $dist_tarball_url = "$mirror/src/5.0/$dist_tarball";
                return ($dist_tarball, $dist_tarball_url)
                    if ($index =~ /href\s*=\s*"\Q$dist_tarball\E"/ms);
            }
        }
    }

    my $json = http_get("https://fastapi.metacpan.org/v1/release/_search?size=1&q=name:perl-${version}");

    my $result;
    unless ($json and $result = decode_json($json)->{hits}{hits}[0]) {
        die "ERROR: Failed to locate perl-${version} tarball.";
    }

    my ($dist_path, $dist_tarball) =
        $result->{_source}{download_url} =~ m[(/authors/id/.+/(perl-${version}.tar.(gz|bz2|xz)))$];
    die "ERROR: Cannot find the tarball for perl-$version\n"
        if !$dist_path and !$dist_tarball;
    my $dist_tarball_url = "https://cpan.metacpan.org${dist_path}";
    return ($dist_tarball, $dist_tarball_url);
}

sub cperl_release {
    my ($self, $version) = @_;
    my %url = (
        "5.22.3" => "https://github.com/perl11/cperl/releases/download/cperl-5.22.3/cperl-5.22.3.tar.gz",
        "5.22.2" => "https://github.com/perl11/cperl/releases/download/cperl-5.22.2/cperl-5.22.2.tar.gz",
        "5.24.0-RC1" => "https://github.com/perl11/cperl/releases/download/cperl-5.24.0-RC1/cperl-5.24.0-RC1.tar.gz",
    );
    # my %digest => {
    #     "5.22.3" => "bcf494a6b12643fa5e803f8e0d9cef26312b88fc",
    #     "5.22.2" => "8615964b0a519cf70d69a155b497de98e6a500d0",
    # };

    my $dist_tarball_url = $url{$version} or die "ERROR: Cannot find the tarball for cperl-$version\n";
    my $dist_tarball = "cperl-${version}.tar.gz";
    return ($dist_tarball, $dist_tarball_url);
}

sub release_detail_perl_local {
    my ($self, $dist, $rd) = @_;
    $rd ||= {};
    my $error = 1;
    my $mirror = $self->cpan_mirror();
    my $tarballs = CPAN::Perl::Releases::perl_tarballs($rd->{version});
    if (keys %$tarballs) {
        for ("tar.bz2", "tar.gz") {
          if (my $x = $tarballs->{$_}) {
                my ($author_path, $name) = $x =~ m|(.+)/(.+?)$|;
                $rd->{tarball_name} = $name;
                $rd->{tarball_url} = "$mirror/authors/id/$x";
                $rd->{checksums_url} = "$mirror/authors/id/$author_path/CHECKSUMS";
                $error = 0;
                last;
            }
        }
    }
    return ($error, $rd);
}

sub release_detail_perl_remote {
    my ($self, $dist, $rd) = @_;
    $rd ||= {};
    my $error = 1;
    my $mirror = $self->cpan_mirror();

    my $version = $rd->{version};

    # # try src/5.0 symlinks, either perl-5.X or perl5.X; favor .tar.bz2 over .tar.gz
    my $index = http_get("https://www.cpan.org/src/5.0/");
    if ($index) {
        for my $prefix ("perl-", "perl") {
            for my $suffix (".tar.bz2", ".tar.gz") {
                my $dist_tarball = "$prefix$version$suffix";
                my $dist_tarball_url = "$mirror/src/5.0/$dist_tarball";
                if ($index =~ /href\s*=\s*"\Q$dist_tarball\E"/ms) {
                    $rd->{tarball_url} = $dist_tarball_url;
                    $rd->{tarball_name} = $dist_tarball;
                    $error = 0;
                    return ($error, $rd);
                }
            }
        }
    }

    my $json = http_get("https://fastapi.metacpan.org/v1/release/_search?size=1&q=name:perl-${version}");

    my $result;
    unless ($json and $result = decode_json($json)->{hits}{hits}[0]) {
        die "ERROR: Failed to locate perl-${version} tarball.";
    }

    my ($dist_dir, $dist_tarball) =
        $result->{_source}{download_url} =~ m[(/authors/id/.+/)(perl-${version}.tar.(gz|bz2|xz))$];
    die "ERROR: Cannot find the tarball for perl-$version\n"
        if !$dist_dir and !$dist_tarball;

    my $url_root = "https://cpan.metacpan.org";

    $rd->{tarball_name} = $dist_tarball;
    $rd->{tarball_url} = "${url_root}${dist_dir}${dist_tarball}";
    $rd->{checksums_url} = "${url_root}${dist_dir}CHECKSUMS";
    $error = 0;

    return ($error, $rd);
}

sub release_detail_cperl_local {
    my ($self, $dist, $rd) = @_;
    $rd ||= {};
    my %url = (
        "cperl-5.22.3" => "https://github.com/perl11/cperl/releases/download/cperl-5.22.3/cperl-5.22.3.tar.gz",
        "cperl-5.22.2" => "https://github.com/perl11/cperl/releases/download/cperl-5.22.2/cperl-5.22.2.tar.gz",
        "cperl-5.24.0-RC1" => "https://github.com/perl11/cperl/releases/download/cperl-5.24.0-RC1/cperl-5.24.0-RC1.tar.gz",
        "cperl-5.24.2" => "https://github.com/perl11/cperl/releases/download/cperl-5.24.2/cperl-5.24.2.tar.gz",
        "cperl-5.25.2" => "https://github.com/perl11/cperl/releases/download/cperl-5.24.2/cperl-5.25.2.tar.gz",
        "cperl-5.26.0" => "https://github.com/perl11/cperl/archive/cperl-5.26.0.tar.gz",
        "cperl-5.26.0-RC1" => "https://github.com/perl11/cperl/archive/cperl-5.26.0-RC1.tar.gz",
        "cperl-5.27.0" => "https://github.com/perl11/cperl/archive/cperl-5.27.0.tar.gz",
    );

    my $error = 1;
    if (my $u = $url{$dist}) {
        $rd->{tarball_name} = "${dist}.tar.gz";
        $rd->{tarball_url} = $u;
        $error = 0;
    }
    return ($error, $rd);
}

sub release_detail_cperl_remote {
    my ($self, $dist, $rd) = @_;
    $rd ||= {};

    my $expect_href = "/perl11/cperl/archive/${dist}.tar.gz";
    my $html = http_get('https://github.com/perl11/cperl/releases/tag/' . $dist);
    my $error = 1;

    if ($html =~ m{ <a \s+ href="($expect_href)" }xsi) {
        $rd->{tarball_name} = "${dist}.tar.gz";
        $rd->{tarball_url}  = "https://github.com" . $1;
        $error = 0;
    } else {
        $error = 1;
    }
    return ($error, $rd);
}

sub release_detail {
    my ($self, $dist) = @_;
    my ($dist_type, $dist_version);

    ($dist_type, $dist_version) = $dist =~ /^ (?: (c?perl) -? )? ( [\d._]+ (?:-RC\d+)? |git|stable|blead)$/x;
    $dist_type = "perl" if $dist_version && !$dist_type;

    my $rd = {
        type => $dist_type,
        version => $dist_version,
        tarball_url => undef,
        tarball_name => undef,
        checksums_url => undef
    };

    # dynamic methods: release_detail_perl_local, release_detail_cperl_local, release_detail_perl_remote, release_detail_cperl_remote
    my $m_local = "release_detail_${dist_type}_local";
    my $m_remote = "release_detail_${dist_type}_remote";

    my ($error) = $self->$m_local($dist, $rd);
    ($error) = $self->$m_remote($dist, $rd) if $error;

    if ($error) {
        die "ERROR: Fail to get the tarball URL for dist: $dist\n";
    }

    return $rd;
}

sub run_command_init {
    my $self = shift;
    my @args = @_;

    if (@args && $args[0] eq '-') {
        if ($self->current_shell_is_bashish) {
            $self->run_command_init_in_bash;
        }
        exit 0;
    }

    $_->mkpath for (grep { ! -d $_ } map { $self->root->$_ } qw(perls dists build etc bin));

    my ($f, $fh) = @_;

    my $etc_dir = $self->root->etc;

    for (["bashrc", "BASHRC_CONTENT"],
         ["cshrc", "CSHRC_CONTENT"],
         ["csh_reinit",  "CSH_REINIT_CONTENT"],
         ["csh_wrapper", "CSH_WRAPPER_CONTENT"],
         ["csh_set_path", "CSH_SET_PATH_CONTENT"],
         ["perlbrew-completion.bash", "BASH_COMPLETION_CONTENT"],
         ["perlbrew.fish", "PERLBREW_FISH_CONTENT" ],
         ["pause-keyring.gpg", "PAUSE_PGP_KEYRING"],
     ) {
        my ($file_name, $method) = @$_;
        my $path = $etc_dir->child ($file_name);
        if (! -f $path) {
            open($fh, ">", $path) or die "Fail to create $path. Please check the permission of $etc_dir and try `perlbrew init` again.";
            print $fh $self->$method;
            close $fh;
        }
        else {
            if (-w $path && open($fh, ">", $path)) {
                print $fh $self->$method;
                close $fh;
            }
            else {
                print "NOTICE: $path already exists and not updated.\n" unless $self->{quiet};
            }
        }
    }

    my $root_dir = $self->root->stringify_with_tilde;
    # Skip this if we are running in a shell that already 'source's perlbrew.
    # This is true during a self-install/self-init.
    # Ref. https://github.com/gugod/App-perlbrew/issues/525
    if ($ENV{PERLBREW_SHELLRC_VERSION}) {
        print("\nperlbrew root ($root_dir) is initialized.\n");
    } else {
        my $shell = $self->current_shell;
        my ($code, $yourshrc);
        if ($shell =~ m/(t?csh)/) {
            $code = "source $root_dir/etc/cshrc";
            $yourshrc = $1 . "rc";
        }
        elsif ($shell =~ m/zsh\d?$/) {
            $code = "source $root_dir/etc/bashrc";
            $yourshrc = $self->_firstrcfile(qw(
                zshenv
                .bash_profile
                .bash_login
                .profile
            )) || "zshenv";
        }
        elsif ($shell =~ m/fish/) {
            $code = ". $root_dir/etc/perlbrew.fish";
            $yourshrc = 'config/fish/config.fish';
        }
        else {
            $code = "source $root_dir/etc/bashrc";
            $yourshrc = $self->_firstrcfile(qw(
                .bash_profile
                .bash_login
                .profile
            )) || ".bash_profile";
        }

        if ($self->home ne App::Perlbrew::Path->new ($self->env('HOME'), ".perlbrew")) {
            my $pb_home_dir = $self->home->stringify_with_tilde;
            if ( $shell =~ m/fish/ ) {
                $code = "set -x PERLBREW_HOME $pb_home_dir\n    $code";
            } else {
                $code = "export PERLBREW_HOME=$pb_home_dir\n    $code";
            }
        }

        print <<INSTRUCTION;

perlbrew root ($root_dir) is initialized.

Append the following piece of code to the end of your ~/${yourshrc} and start a
new shell, perlbrew should be up and fully functional from there:

    $code

Simply run `perlbrew` for usage details.

Happy brewing!

INSTRUCTION
    }

}

sub run_command_init_in_bash {
    print BASHRC_CONTENT();
}

sub run_command_self_install {
    my $self = shift;

    my $executable = $0;
    my $target = $self->root->bin ("perlbrew");

    if (files_are_the_same($executable, $target)) {
        print "You are already running the installed perlbrew:\n\n    $executable\n";
        exit;
    }

    $self->root->bin->mkpath;

    open my $fh, "<", $executable;
    my @lines =  <$fh>;
    close $fh;

    $lines[0] = $self->system_perl_shebang . "\n";

    open $fh, ">", $target;
    print $fh $_ for @lines;
    close $fh;

    chmod(0755, $target);

    my $path = $target->stringify_with_tilde;

    print "perlbrew is installed: $path\n" unless $self->{quiet};

    $self->run_command_init();
    return;
}

sub do_install_git {
    my ($self, $dist) = @_;
    my $dist_name;
    my $dist_git_describe;
    my $dist_version;

    opendir my $cwd_orig, ".";

    chdir $dist;

    if (`git describe` =~ /v((5\.\d+\.\d+(?:-RC\d)?)(-\d+-\w+)?)$/) {
        $dist_name = 'perl';
        $dist_git_describe = "v$1";
        $dist_version = $2;
    }

    chdir $cwd_orig;

    require File::Spec;
    my $dist_extracted_dir = File::Spec->rel2abs($dist);
    $self->do_install_this($dist_extracted_dir, $dist_version, "$dist_name-$dist_version");
    return;
}

sub do_install_url {
    my ($self, $dist) = @_;
    my $dist_name = 'perl';
    # need the period to account for the file extension
    my ($dist_version) = $dist =~ m/-([\d.]+(?:-RC\d+)?|git)\./;
    my ($dist_tarball) = $dist =~ m{/([^/]*)$};

    my $dist_tarball_path = $self->root->dists ($dist_tarball);
    my $dist_tarball_url  = $dist;
    $dist = "$dist_name-$dist_version"; # we install it as this name later

    if ($dist_tarball_url =~ m/^file/) {
        print "Installing $dist from local archive $dist_tarball_url\n";
        $dist_tarball_url =~ s/^file:\/+/\//;
        $dist_tarball_path = $dist_tarball_url;
    }
    else {
        print "Fetching $dist as $dist_tarball_path\n";
        my $error = http_download($dist_tarball_url, $dist_tarball_path);
        die "ERROR: Failed to download $dist_tarball_url\n" if $error;
    }

    my $dist_extracted_path = $self->do_extract_tarball($dist_tarball_path);
    $self->do_install_this($dist_extracted_path, $dist_version, $dist);
    return;
}

sub do_extract_tarball {
    my ($self, $dist_tarball) = @_;

    # Assuming the dir extracted from the tarball is named after the tarball.
    my $dist_tarball_basename = $dist_tarball->basename (qr/\.tar\.(?:gz|bz2|xz)$/);

    # Note that this is incorrect for blead.
    my $workdir = $self->builddir->child ($dist_tarball_basename);
    $workdir->rmpath;
    $workdir->mkpath;
    my $extracted_dir;

    # Was broken on Solaris, where GNU tar is probably
    # installed as 'gtar' - RT #61042
    my $tarx =
        ($^O =~ /solaris|aix/ ? 'gtar ' : 'tar ') .
        ( $dist_tarball =~ m/xz$/  ? 'xJf' :
          $dist_tarball =~ m/bz2$/ ? 'xjf' : 'xzf' );

    my $extract_command = "cd $workdir; $tarx $dist_tarball";
    die "Failed to extract $dist_tarball" if system($extract_command);

    my @things = $workdir->children;
    if (@things == 1) {
        $extracted_dir = App::Perlbrew::Path->new ($things[0]);
    }

    unless (defined($extracted_dir) && -d $extracted_dir) {
        die "Failed to find the extracted directory under $workdir";
    }

    return $extracted_dir;
}

# Search for directories inside a extracted tarball downloaded as perl "blead"
# Use a Schwartzian Transform in case there are lots of dirs that
# look like "perl-$SHA1", which is what's inside blead.tar.gz,
# so we stat each one only once, ordering (descending )the directories per mtime
# Expects as parameters:
# - the path to the extracted "blead" tarball
# - an array reference, that will be used to cache all contents from the read directory
# Returns the most recent directory which name matches the expected one.
sub search_blead_dir {
    my ($build_dir, $contents_ref) = @_;
    local *DIRH;
    opendir DIRH, $build_dir or die "Couldn't open ${build_dir}: $!";
    @{$contents_ref} = grep {!/^\./ && -d $build_dir->child ($_)} readdir DIRH;
    closedir DIRH or warn "Couldn't close ${build_dir}: $!";
    my @candidates = grep { m/^perl-blead-[0-9a-f]{4,40}$/ } @{$contents_ref};
    @candidates =   map  { $_->[0] }
                    sort { $b->[1] <=> $a->[1] } # descending
                    map  { [ $_, (stat( $build_dir->child ($_) ))[9] ] } @candidates;
    if (scalar(@candidates) > 0) {
        # take the newest one
        return $candidates[0];
    } else {
        return;
    }
}

sub do_install_blead {
    my ($self, $dist) = @_;
    my $dist_name           = 'perl';
    my $dist_git_describe   = 'blead';
    my $dist_version        = 'blead';

    # We always blindly overwrite anything that's already there,
    # because blead is a moving target.
    my $dist_tarball = 'blead.tar.gz';
    my $dist_tarball_path = $self->root->dists ($dist_tarball);
    print "Fetching $dist_git_describe as $dist_tarball_path\n";

    my $error = http_download("https://perl5.git.perl.org/perl.git/snapshot/$dist_tarball", $dist_tarball_path);

    if ($error) {
        die "\nERROR: Failed to download perl-blead tarball.\n\n";
    }

    # Returns the wrong extracted dir for blead
    $self->do_extract_tarball($dist_tarball_path);

    my $build_dir = $self->builddir;
    my @contents;
    my $dist_extracted_subdir = search_blead_dir($build_dir, \@contents);

    # there might be an additional level on $build_dir
    unless (defined($dist_extracted_subdir)) {
        warn "No candidate found at $build_dir, trying a level deeper";
        for my $item (@contents) {
            my $another_sub = $build_dir->child ($item);
            $dist_extracted_subdir = search_blead_dir($another_sub);
            if (defined($dist_extracted_subdir)) {
               $build_dir = $another_sub;
                last;
            }
        }
    }

    die "Could not identify where is the source code to build under $build_dir, aborting..." unless (defined($dist_extracted_subdir));
    my $dist_extracted_dir = $build_dir->child ($dist_extracted_subdir);
    $self->do_install_this($dist_extracted_dir, $dist_version, "$dist_name-$dist_version");
    return;
}

sub resolve_stable_version {
    my ($self) = @_;

    my ($latest_ver, $latest_minor);
    for my $cand ($self->available_perls) {
        my ($ver, $minor) = $cand =~ m/^perl-(5\.(6|8|[0-9]+[02468])\.[0-9]+)$/
            or next;
        ($latest_ver, $latest_minor) = ($ver, $minor)
            if !defined $latest_minor
            || $latest_minor < $minor;
    }

    die "Can't determine latest stable Perl release\n"
        if !defined $latest_ver;

    return $latest_ver;
}

sub do_install_release {
    my ($self, $dist, $dist_version) = @_;

    my $rd = $self->release_detail($dist);
    my $dist_type = $rd->{type};

    die "\"$dist\" does not look like a perl distribution name. " unless $dist_type && $dist_version =~ /^\d\./;

    my $dist_tarball = $rd->{tarball_name};
    my $dist_tarball_url = $rd->{tarball_url};
    my $dist_tarball_path = $self->root->dists ($dist_tarball);

    if (-f $dist_tarball_path) {
        print "Using the previously fetched ${dist_tarball}\n"
            if $self->{verbose};
    }
    else {
        print "Fetching perl $dist_version as $dist_tarball_path\n" unless $self->{quiet};
        $self->run_command_download($dist);
    }
    $self->verify_tarball($dist_tarball_path);
    my $dist_extracted_path = $self->do_extract_tarball($dist_tarball_path);
    $self->do_install_this($dist_extracted_path, $dist_version, $dist);
    return;
}

sub run_command_install {
    my ($self, $dist, $opts) = @_;

    unless ($dist) {
        $self->run_command_help("install");
        exit(-1);
    }

    $self->{dist_name} = $dist; # for help msg generation, set to non
                                # normalized name

    my ($dist_type, $dist_version);
    if (($dist_type, $dist_version) = $dist =~ /^(?:(c?perl)-?)?([\d._]+(?:-RC\d+)?|git|stable|blead)$/) {
        my $dist_version = ($dist_version eq 'stable' ? $self->resolve_stable_version : $2);
        $dist_version = $self->resolve_stable_version if $dist_version eq 'stable';
        $dist_type ||= "perl";
        $dist = "${dist_type}-${dist_version}"; # normalize dist name

        my $installation_name = ($self->{as} || $dist) . $self->{variation} . $self->{append};
        if (not $self->{force} and $self->is_installed($installation_name)) {
            die "\nABORT: $installation_name is already installed.\n\n";
        }

        if ($dist_type eq 'perl' && $dist_version eq 'blead') {
            $self->do_install_blead($dist);
        }
        else {
            $self->do_install_release($dist, $dist_version);
        }

    }
    # else it is some kind of special install:
    elsif (-d "$dist/.git") {
        $self->do_install_git($dist);
    }
    elsif (-f $dist) {
        $self->do_install_archive($dist);
    }
    elsif ($dist =~ m/^(?:https?|ftp|file)/) { # more protocols needed?
        $self->do_install_url($dist);
    }
    else {
        die "Unknown installation target \"$dist\", abort.\nPlease see `perlbrew help` " .
            "for the instruction on using the install command.\n\n";
    }

    if ($self->{switch}) {
        if (defined(my $installation_name = $self->{installation_name})) {
            $self->switch_to($installation_name)
        }
        else {
            warn "can't switch, unable to infer final destination name.\n\n";
        }
    }
    return;
}

sub check_and_calculate_variations {
    my $self = shift;
    my @both = @{$self->{both}};

    if ($self->{'all-variations'}) {
        @both = keys %flavor;
    }
    elsif ($self->{'common-variations'}) {
        push @both, grep $flavor{$_}{common}, keys %flavor;
    }

    # check the validity of the varitions given via 'both'
    for my $both (@both) {
        $flavor{$both} or die "$both is not a supported flavor.\n\n";
        $self->{$both} and die "options --both $both and --$both can not be used together";
        if (my $implied_by = $flavor{$both}{implied_by}) {
            $self->{$implied_by} and die "options --both $both and --$implied_by can not be used together";
        }
    }

    # flavors selected always
    my $start = '';
    $start .= "-$_" for grep $self->{$_}, keys %flavor;

    # make variations
    my @var = $start;
    for my $both (@both) {
        my $append = join('-', $both, grep defined, $flavor{$both}{implies});
        push @var, map "$_-$append", @var;
    }

    # normalize the variation names
    @var = map { join '-', '', sort { $flavor{$a}{ix} <=> $flavor{$b}{ix} } grep length, split /-+/, $_ } @var;
    s/(\b\w+\b)(?:-\1)+/$1/g for @var; # remove duplicate flavors

    # After inspecting perl Configure script this seems to be the most
    # reliable heuristic to determine if perl would have 64bit IVs by
    # default or not:
    if ($Config::Config{longsize} >= 8) {
        # We are in a 64bit platform. 64int and 64all are always set but
        # we don't want them to appear on the final perl name
        s/-64\w+//g for @var;
    }

    # remove duplicated variations
    my %var = map { $_ => 1 } @var;
    sort keys %var;
}

sub run_command_install_multiple {
    my ($self, @dists) = @_;

    unless (@dists) {
        $self->run_command_help("install-multiple");
        exit(-1);
    }

    die "--switch can not be used with command install-multiple.\n\n"
        if $self->{switch};
    die "--as can not be used when more than one distribution is given.\n\n"
        if $self->{as} and @dists > 1;

    my @variations = $self->check_and_calculate_variations;
    print join("\n",
               "Compiling the following distributions:",
               map("    $_$self->{append}", @dists),
               "  with the following variations:",
               map((/-(.*)/ ? "    $1" : "    default"), @variations),
               "", "");

    my @ok;
    for my $dist (@dists) {
        for my $variation (@variations) {
            local $@;
            eval {
                $self->{$_} = '' for keys %flavor;
                $self->{$_} = 1 for split /-/, $variation;
                $self->{variation} = $variation;
                $self->{installation_name} = undef;

                $self->run_command_install($dist);
                push @ok, $self->{installation_name};
            };
            if ($@) {
                $@ =~ s/\n+$/\n/;
                print "Installation of $dist$variation failed: $@";
            }
        }
    }

    print join("\n",
               "",
               "The following perls have been installed:",
               map ("    $_", grep defined, @ok),
               "", "");
    return
}

sub run_command_download {
    my ($self, $dist) = @_;

    $dist = $self->resolve_stable_version
        if $dist && $dist eq 'stable';

    my $rd = $self->release_detail($dist);

    my $dist_tarball = $rd->{tarball_name};
    my $dist_tarball_url = $rd->{tarball_url};
    my $dist_tarball_path = $self->root->dists ($dist_tarball);

    my $download = sub {
        my ($src, $dst) = @_;
        if (-f $dst && $self->{force}) {
            unlink($dst);
        } elsif (-f $dst) {
            print "$dist_tarball already exists\n";
            return;
        }
        warn "Download $src to $dst\n" unless $self->{quiet};
        my $error = http_download($src, $dst);
        die "ERROR: Failed to download $src\n" if $error;
    };
      
    &$download($dist_tarball_url, $dist_tarball_path);

    if ($rd->{checksums_url}) {
        my $chk_file =  "${dist_tarball_path}.CHECKSUMS";
        &$download($rd->{checksums_url}, $chk_file);
    }
}

sub has_gpg {
    my $self = shift;
    my $gpg_cmd = shift || 'gpg';
    my @options = ("${gpg_cmd}", "${gpg_cmd}2");
    for my $p (@options) {
        my $cmd = "$p --version 2>&1";
        if (qx($cmd) =~ /GnuPG/) {
            return $p;
        }
    }
    return;
}

sub gpgv_verified_output {
    my $self = shift;
    my $file = shift;
    my $keyring = shift || $self->keyring();

    die "[ ERROR ] cannot gpgv_verify non existing file: $file"
        unless -f $file;
    die "[ ERROR ] keyring $keyring does not exist, download it using $0 download-keyring"
        unless -f $keyring;

    my $fail = sub {
        die "[ ERROR ] PGP signature verification FAILED for $file: ".shift."\n";
    };

    my @cmd = ($self->has_gpg("gpgv"),
               "-q", "--logger-fd=2",
               "--keyring", $keyring,
               "--output", '-',
               $file);
    

    open(my $gpg_p, '-|', @cmd) or &$fail($!);
    my $verified_output = do { local undef $/; <$gpg_p> };
    close $gpg_p;

    my $exit = $? >> 8;
    &$fail("Exit $exit") if $exit;
    &$fail("No output") unless $verified_output;

    return $verified_output;
}

sub keyring {
    my $self = shift;
    my $keyring = joinpath($self->root, 'etc', 'pause-keyring.gpg');
    return $keyring;
}


sub run_command_download_keyring {
     my $self = shift;
     my $gpg = $self->has_gpg;
     die "[ ERROR ] Cannot find GnuPG executable\n" unless $gpg;

     my $PGP_PAUSE_KEYID = "0x328DA867450F89EC";
     my $keyring_url = "https://keyserver.ubuntu.com/pks/lookup?op=get&search="
       . $PGP_PAUSE_KEYID;

     my $keyring = $self->keyring;

     require File::Temp;
     my $tmp = File::Temp::tmpnam(); # need file to not exist for http_download
                                     # to work

     print "Downloading PAUSE signing keys from $keyring_url\n";
     http_download($keyring_url, $tmp);

     my $r = system($gpg, "--no-verbose", "--dearmour", "-o", $keyring, $tmp);
     unlink($tmp);
     if ($r == 0) {
         return 1;
     } else {
         die "[ ERROR ] Cannot dearmour keyring $!";
     }
}

sub verify_tarball {
    my ($self, $tarball_path, $chk_file) = @_;

    $chk_file ||= $tarball_path.".CHECKSUMS";

    my $chk_str;
    if ($self->has_gpg) {
        $chk_str = $self->gpgv_verified_output($chk_file);
    } else {
        die "[ ERROR ] gpg not installed, cannot verify CHECKSUMS against PAUSE signing keys\n";
    }

    return $self->digest_verify($tarball_path, $chk_str);
}

sub digest_verify {
    my ($self, $tarball_path, $chk_str) = @_;

    # To verify autxhors/CHECKSUMS file
    # (copied/pasted from cpanm/Menlo-Legacy/lib/Menlo/CLI/Compat.pm)

    my ($tarball_name) = (split("/", $tarball_path))[-1];

    $chk_str =~ s/\015?\012/\n/g;

    require Safe;                 # no fatpack
    my $chksum = Safe->new->reval($chk_str);
    if (!ref $chksum or ref $chksum ne 'HASH') {
        die "[ ERROR ] \$chk_str does not contain expected data\n";
    }
    if (my $sha = $chksum->{$tarball_name}{sha256}) {
        my $d;
        eval {
            require Digest::SHA;
            $d = Digest::SHA->new("256");
        };
        if ($@) {
            $d = Digest::SHA::PurePerl->new("256");
        }
        $d->addfile($tarball_path);
        my $hex = $d->hexdigest;
        if ($hex eq $sha) {
            print "[ OK ] Checksum for $tarball_name: Verified!\n";
            return 1;
        } else {
            die "[ ERROR ] Checksum verification FAILED for $tarball_path\n";
        }
    } else {
        die "[ ERROR ] SHA256 Checksum for $tarball_name not found in CHECKSUMS.\n";
    }
}


sub purify {
    my ($self, $envname) = @_;
    my @paths = grep { index($_, $self->home) < 0 && index($_, $self->root) < 0 } split /:/, $self->env($envname);
    return wantarray ? @paths : join(":", @paths);
}

sub system_perl_executable {
    my ($self) = @_;

    my $system_perl_executable = do {
        local $ENV{PATH} = $self->pristine_path;
        `perl -MConfig -e 'print \$Config{perlpath}'`
    };

    return $system_perl_executable;
}

sub system_perl_shebang {
    my ($self) = @_;
    return $Config{sharpbang}. $self->system_perl_executable;
}

sub pristine_path {
    my ($self) = @_;
    return $self->purify("PATH");
}

sub pristine_manpath {
    my ($self) = @_;
    return $self->purify("MANPATH");
}

sub run_command_display_system_perl_executable {
    print $_[0]->system_perl_executable . "\n";
}

sub run_command_display_system_perl_shebang {
    print $_[0]->system_perl_shebang . "\n";
}

sub run_command_display_pristine_path {
    print $_[0]->pristine_path . "\n";
}

sub run_command_display_pristine_manpath {
    print $_[0]->pristine_manpath . "\n";
}

sub do_install_archive {
    require File::Basename;

    my $self = shift;
    my $dist_tarball_path = shift;
    my $dist_version;
    my $installation_name;

    if ($dist_tarball_path->basename =~ m{(c?perl)-?(5.+)\.tar\.(gz|bz2|xz)\Z}) {
        my $perl_variant = $1;
        $dist_version = $2;
        $installation_name = "${perl_variant}-${dist_version}";
    }

    unless ($dist_version && $installation_name) {
        die "Unable to determine perl version from archive filename.\n\nThe archive name should look like perl-5.x.y.tar.gz or perl-5.x.y.tar.bz2 or perl-5.x.y.tar.xz\n";
    }

    my $dist_extracted_path = $self->do_extract_tarball($dist_tarball_path);
    $self->do_install_this($dist_extracted_path, $dist_version, $installation_name);
    return;
}

sub do_install_this {
    my ($self, $dist_extracted_dir, $dist_version, $installation_name) = @_;

    my $variation = $self->{variation};
    my $append = $self->{append};
    my $looks_like_we_are_installing_cperl =  $dist_extracted_dir =~ /\/ cperl- /x;

    $self->{dist_extracted_dir} = $dist_extracted_dir;
    $self->{log_file} = $self->root->child ("build.${installation_name}${variation}${append}.log");

    my @d_options = @{ $self->{D} };
    my @u_options = @{ $self->{U} };
    my @a_options = @{ $self->{A} };
    my $sitecustomize = $self->{sitecustomize};
    my $destdir = $self->{destdir};
    $installation_name = $self->{as} if $self->{as};
    $installation_name .= "$variation$append";

    $self->{installation_name} = $installation_name;

    if ($sitecustomize) {
        die "Could not read sitecustomize file '$sitecustomize'\n"
            unless -r $sitecustomize;
        push @d_options, "usesitecustomize";
    }

    if ($self->{noman}) {
        push @d_options, qw/man1dir=none man3dir=none/;
    }

    for my $flavor (keys %flavor) {
        $self->{$flavor} and push @d_options, $flavor{$flavor}{d_option}
    }

    my $perlpath = $self->root->perls ($installation_name);
    my $patchperl = $self->root->bin ("patchperl");

    unless (-x $patchperl && -f _) {
        $patchperl = "patchperl";
    }

    unshift @d_options, qq(prefix=$perlpath);
    push @d_options, "usedevel" if $dist_version =~ /5\.\d[13579]|git|blead/;

    push @d_options, "usecperl" if $looks_like_we_are_installing_cperl;

    my $version = $self->comparable_perl_version($dist_version);
    if (defined $version and $version < $self->comparable_perl_version('5.6.0')) {
        # ancient perls do not support -A for Configure
        @a_options = ();
    } else {
        unless (grep { /eval:scriptdir=/} @a_options) {
            push @a_options, "'eval:scriptdir=${perlpath}/bin'";
        }
    }

    print "Installing $dist_extracted_dir into " . $self->root->perls ($installation_name)->stringify_with_tilde . "\n\n";
    print <<INSTALL if !$self->{verbose};
This could take a while. You can run the following command on another shell to track the status:

  tail -f ${\ $self->{log_file}->stringify_with_tilde }

INSTALL

    my @preconfigure_commands = (
        "cd $dist_extracted_dir",
        "rm -f config.sh Policy.sh",
    );
    push @preconfigure_commands, $patchperl unless $self->{"no-patchperl"} || $looks_like_we_are_installing_cperl;

    my $configure_flags = $self->env("PERLBREW_CONFIGURE_FLAGS") || '-de';

    my @configure_commands = (
        "sh Configure $configure_flags " .
            join( ' ',
                ( map { qq{'-D$_'} } @d_options ),
                ( map { qq{'-U$_'} } @u_options ),
                ( map { qq{'-A$_'} } @a_options ),
            ),
        (defined $version and $version < $self->comparable_perl_version('5.8.9'))
                ? ("$^X -i -nle 'print unless /command-line/' makefile x2p/makefile")
                : ()
    );

    my $make = $ENV{MAKE} || ($^O eq "solaris" ? 'gmake' : 'make');
    my @build_commands = (
        $make . ' ' . ($self->{j} ? "-j$self->{j}" : "")
    );

    # Test via "make test_harness" if available so we'll get
    # automatic parallel testing via $HARNESS_OPTIONS. The
    # "test_harness" target was added in 5.7.3, which was the last
    # development release before 5.8.0.
    my $test_target = "test";
    if ($dist_version =~ /^5\.(\d+)\.(\d+)/
        && ($1 >= 8 || $1 == 7 && $2 == 3)) {
        $test_target = "test_harness";
    }
    local $ENV{TEST_JOBS}=$self->{j}
      if $test_target eq "test_harness" && ($self->{j}||1) > 1;

    my @install_commands = ("${make} install" . ($destdir ? " DESTDIR=$destdir" : q||));
    unshift @install_commands, "${make} $test_target" unless $self->{notest};
    # Whats happening here? we optionally join with && based on $self->{force}, but then subsequently join with && anyway?
    @install_commands    = join " && ", @install_commands unless ($self->{force});

    my $cmd = join " && ",
    (
        @preconfigure_commands,
        @configure_commands,
        @build_commands,
        @install_commands
    );

    $self->{log_file}->unlink;

    if ($self->{verbose}) {
        $cmd = "($cmd) 2>&1 | tee $self->{log_file}";
        print "$cmd\n" if $self->{verbose};
    } else {
        $cmd = "($cmd) >> '$self->{log_file}' 2>&1 ";
    }

    delete $ENV{$_} for qw(PERL5LIB PERL5OPT AWKPATH);

    if ($self->do_system($cmd)) {
        my $newperl = $self->root->perls ($installation_name)->perl;
        unless (-e $newperl) {
            $self->run_command_symlink_executables($installation_name);
        }

        eval { $self->append_log('##### Brew Finished #####') };

        if ($sitecustomize) {
            my $capture = $self->do_capture("$newperl -V:sitelib");
            my ($sitelib) = $capture =~ m/sitelib='([^']*)';/;
            $sitelib = $destdir . $sitelib if $destdir;
			$sitelib = App::Perlbrew::Path->new ($sitelib);
            $sitelib->mkpath;
            my $target = $sitelib->child ("sitecustomize.pl");
            open my $dst, ">", $target
                or die "Could not open '$target' for writing: $!\n";
            open my $src, "<", $sitecustomize
                or die "Could not open '$sitecustomize' for reading: $!\n";
            print {$dst} do { local $/; <$src> };
        }

        my $version_file =
          $self->root->perls ($installation_name)->version_file;

        if (-e $version_file) {
            $version_file->unlink
              or die "Could not unlink $version_file file: $!\n";
        }

        print "$installation_name is successfully installed.\n";
    }
    else {
        eval { $self->append_log('##### Brew Failed #####') };
        die $self->INSTALLATION_FAILURE_MESSAGE;
    }
    return;
}

sub do_install_program_from_url {
    my ($self, $url, $program_name, $body_filter) = @_;

    my $out = $self->root->bin ($program_name);

    if (-f $out && !$self->{force} && !$self->{yes}) {
        require ExtUtils::MakeMaker;

        my $ans = ExtUtils::MakeMaker::prompt("\n$out already exists, are you sure to override ? [y/N]", "N");

        if ($ans !~ /^Y/i) {
            print "\n$program_name installation skipped.\n\n" unless $self->{quiet};
            return;
        }
    }

    my $body = http_get($url) or die "\nERROR: Failed to retrieve $program_name executable.\n\n";

    unless ($body =~ m{\A#!/}s) {
        my $x = App::Perlbrew::Path->new ($self->env('TMPDIR') || "/tmp", "${program_name}.downloaded.$$");
        my $message = "\nERROR: The downloaded $program_name program seem to be invalid. Please check if the following URL can be reached correctly\n\n\t$url\n\n...and try again latter.";

        unless (-f $x) {
            open my $OUT, ">", $x;
            print $OUT $body;
            close($OUT);
            $message .= "\n\nThe previously downloaded file is saved at $x for manual inspection.\n\n";
        }

        die $message;
    }

    if ($body_filter && ref($body_filter) eq "CODE") {
        $body = $body_filter->($body);
    }

    $self->root->bin->mkpath;
    open my $OUT, '>', $out or die "cannot open file($out): $!";
    print $OUT $body;
    close $OUT;
    chmod 0755, $out;
    print "\n$program_name is installed to\n\n    $out\n\n" unless $self->{quiet};
}

sub do_exit_with_error_code {
  my ($self, $code) = @_;
  exit($code);
}

sub do_system_with_exit_code {
  my ($self, @cmd) = @_;
  return system(@cmd);
}

sub do_system {
  my ($self, @cmd) = @_;
  return ! $self->do_system_with_exit_code(@cmd);
}

sub do_capture {
  my ($self, @cmd) = @_;
  require Capture::Tiny;
  return Capture::Tiny::capture(sub {
    $self->do_system(@cmd);
  });
}

sub format_perl_version {
    my $self    = shift;
    my $version = shift;
    return sprintf "%d.%d.%d",
      substr($version, 0, 1),
      substr($version, 2, 3),
      substr($version, 5) || 0;

}

sub installed_perls {
    my $self    = shift;

    my @result;
    my $root = $self->root;

    for my $installation ($root->perls->list) {
        my $name         = $installation->name;
        my $executable   = $installation->perl;
        next unless -f $executable;

        my $version_file = $installation->version_file;
        my $ctime        = localtime((stat $executable)[ 10 ]); # localtime in scalar context!

        my $orig_version;
        if (-e $version_file) {
            open my $fh, '<', $version_file;
            local $/;
            $orig_version = <$fh>;
            chomp $orig_version;
        } else {
            $orig_version = `$executable -e 'print \$]'`;
            if (defined $orig_version and length $orig_version) {
                if (open my $fh, '>', $version_file ) {
                    print {$fh} $orig_version;
                }
            }
        }

        push @result, {
            name        => $name,
            orig_version=> $orig_version,
            version     => $self->format_perl_version($orig_version),
            is_current  => ($self->current_perl eq $name) && !($self->current_lib),
            libs => [ $self->local_libs($name) ],
            executable  => $executable,
            dir => $installation,
            comparable_version => $self->comparable_perl_version($orig_version),
            ctime        => $ctime,
        };
    }

    return sort { ( $self->{reverse}
                  ? ( $a->{comparable_version} <=> $b->{comparable_version} or $b->{name} cmp $a->{name} )
                  : ( $b->{comparable_version} <=> $a->{comparable_version} or $a->{name} cmp $b->{name} ) ) } @result;
}

sub compose_locallib {
	my ($self, $perl_name, $lib_name) = @_;

	return join '@', $perl_name, $lib_name;
}

sub decompose_locallib {
	my ($self, $name) = @_;

	return split '@', $name;
}

sub enforce_localib {
	my ($self, $name) = @_;

    $name =~ s/^/@/ unless $name =~ m/@/;

	return $name;
}

sub local_libs {
    my ($self, $perl_name) = @_;

    my $current = $self->current_env;
    my @libs = map {
        my $name = $_->basename;
        my ($p, $l) = $self->decompose_locallib ($name);
        +{
            name       => $name,
            is_current => $name eq $current,
            perl_name  => $p,
            lib_name   => $l,
            dir        => $_,
        }
    } $self->home->child ("libs")->children;
    if ($perl_name) {
        @libs = grep { $perl_name eq $_->{perl_name} } @libs;
    }
    return @libs;
}

sub is_installed {
    my ($self, $name) = @_;
    return grep { $name eq $_->{name} } $self->installed_perls;
}

sub assert_known_installation {
    my ($self, $name) = @_;
    return 1 if $self->is_installed($name);
    die "ERROR: The installation \"$name\" is unknown\n\n";
}

# Return a hash of PERLBREW_* variables
sub perlbrew_env {
    my ($self, $name) = @_;
    my ($perl_name, $lib_name);

    if ($name) {
        ($perl_name, $lib_name) = $self->resolve_installation_name($name);

        unless ($perl_name) {
            die "\nERROR: The installation \"$name\" is unknown.\n\n";
        }

        unless (!$lib_name || grep { $_->{lib_name} eq $lib_name } $self->local_libs($perl_name)) {
            die "\nERROR: The lib name \"$lib_name\" is unknown.\n\n";
        }
    }

    my %env = (
        PERLBREW_VERSION => $VERSION,
        PERLBREW_PATH    => $self->root->bin,
        PERLBREW_MANPATH => "",
        PERLBREW_ROOT => $self->root
    );

    require local::lib;
    my $pb_home = $self->home;
    my $current_local_lib_root = $self->env("PERL_LOCAL_LIB_ROOT") || "";
    my $current_local_lib_context = local::lib->new;
    my @perlbrew_local_lib_root =  uniq(grep { /\Q${pb_home}\E/ } split(/:/, $current_local_lib_root));
    if ($current_local_lib_root =~ /^\Q${pb_home}\E/) {
        $current_local_lib_context = $current_local_lib_context->activate($_) for @perlbrew_local_lib_root;
    }

    if ($perl_name) {
        my $installation = $self->root->perls ($perl_name);
        if(-d $installation->child("bin")) {
            $env{PERLBREW_PERL}    = $perl_name;
            $env{PERLBREW_PATH}   .= ":" . $installation->child ("bin");
            $env{PERLBREW_MANPATH} = $installation->child ("man")
        }

        if ($lib_name) {
            $current_local_lib_context = $current_local_lib_context->deactivate($_) for @perlbrew_local_lib_root;

            my $base = $self->home->child ("libs", "${perl_name}\@${lib_name}");

            if (-d $base) {
                $current_local_lib_context = $current_local_lib_context->activate($base);

                if ($self->env('PERLBREW_LIB_PREFIX')) {
                    unshift
                        @{$current_local_lib_context->libs},
                            $self->env('PERLBREW_LIB_PREFIX');
                }

                $env{PERLBREW_PATH}    = $base->child ("bin") . ":" . $env{PERLBREW_PATH};
                $env{PERLBREW_MANPATH} = $base->child ("man") . ":" . $env{PERLBREW_MANPATH};
                $env{PERLBREW_LIB}  = $lib_name;
            }
        } else {
            $current_local_lib_context = $current_local_lib_context->deactivate($_) for @perlbrew_local_lib_root;
            $env{PERLBREW_LIB} = undef;
        }

        my %ll_env = $current_local_lib_context->build_environment_vars;
        delete $ll_env{PATH};
        for my $key (keys %ll_env) {
            $env{$key} = $ll_env{$key};
        }
    } else {
        $current_local_lib_context = $current_local_lib_context->deactivate($_) for @perlbrew_local_lib_root;

        my %ll_env = $current_local_lib_context->build_environment_vars;
        delete $ll_env{PATH};
        for my $key (keys %ll_env) {
            $env{$key} = $ll_env{$key};
        }
        $env{PERLBREW_LIB} = undef;
        $env{PERLBREW_PERL} = undef;
    }

    return %env;
}

sub run_command_list {
    my $self       = shift;
    my $is_verbose = $self->{verbose};

    for my $i ($self->installed_perls) {
        printf "%2s %-20s %-20s %s\n",
            $i->{is_current} ? '*' : '',
            $i->{name},
            ( $is_verbose ?
                (index($i->{name}, $i->{version}) < 0) ? "($i->{version})" : ''
              : '' ),
            ( $is_verbose ? "(installed on $i->{ctime})" : '' );

        for my $lib (@{$i->{libs}}) {
            print $lib->{is_current} ? "* " : "  ",
                $lib->{name}, "\n"
        }
    }

    return 0;
}

sub launch_sub_shell {
    my ($self, $name) = @_;
    my $shell = $self->env('SHELL');

    my $shell_opt = "";

    if ($shell =~ /\/zsh\d?$/) {
        $shell_opt = "-d -f";

        if ($^O eq 'darwin') {
            my $root_dir = $self->root;
            print <<"WARNINGONMAC"
--------------------------------------------------------------------------------
WARNING: zsh perlbrew sub-shell is not working on Mac OSX Lion.

It is known that on MacOS Lion, zsh always resets the value of PATH on launching
a sub-shell. Effectively nullify the changes required by perlbrew sub-shell. You
may `echo \$PATH` to examine it and if you see perlbrew related paths are in the
end, instead of in the beginning, you are unfortunate.

You are advised to include the following line to your ~/.zshenv as a better
way to work with perlbrew:

    source $root_dir/etc/bashrc

--------------------------------------------------------------------------------
WARNINGONMAC

        }
    }

    my %env = ($self->perlbrew_env($name), PERLBREW_SKIP_INIT => 1);

    unless ($ENV{PERLBREW_VERSION}) {
        my $root = $self->root;
        # The user does not source bashrc/csh in their shell initialization.
        $env{PATH}    = $env{PERLBREW_PATH}    . ":" . join ":", grep { !/$root\/bin/ } split ":", $ENV{PATH};
        $env{MANPATH} = $env{PERLBREW_MANPATH} . ":" . join ":", grep { !/$root\/man/ }
            ( defined($ENV{MANPATH}) ? split(":", $ENV{MANPATH}) : () );
    }

    my $command = "env ";
    while (my ($k, $v) = each(%env)) {
        no warnings "uninitialized";
        $command .= "$k=\"$v\" ";
    }
    $command .= " $shell $shell_opt";

    my $pretty_name = defined($name) ? $name : "the default perl";
    print "\nA sub-shell is launched with $pretty_name as the activated perl. Run 'exit' to finish it.\n\n";
    exec($command);
}

sub run_command_use {
    my $self = shift;
    my $perl = shift;

    if ( !$perl ) {
        my $current = $self->current_env;
        if ($current) {
            print "Currently using $current\n";
        } else {
            print "No version in use; defaulting to system\n";
        }
        return;
    }

    $self->launch_sub_shell($perl);

}

sub run_command_switch {
    my ($self, $dist, $alias) = @_;

    unless ( $dist ) {
        my $current = $self->current_env;
        printf "Currently switched %s\n",
            ( $current ? "to $current" : 'off' );
        return;
    }

    $self->switch_to($dist, $alias);
}

sub switch_to {
    my ($self, $dist, $alias) = @_;

    die "Cannot use for alias something that starts with 'perl-'\n"
      if $alias && $alias =~ /^perl-/;

    die "${dist} is not installed\n" unless -d $self->root->perls ($dist);

    if ($self->env("PERLBREW_SHELLRC_VERSION") && $self->current_shell_is_bashish) {
        local $ENV{PERLBREW_PERL} = $dist;
        my $HOME = $self->env('HOME');
        my $pb_home = $self->home;

        $pb_home->mkpath;
        system("$0 env $dist > " . $pb_home->child ("init"));

        print "Switched to $dist.\n\n";
    }
    else {
        $self->launch_sub_shell($dist);
    }
}

sub run_command_off {
    my $self = shift;
    $self->launch_sub_shell;
}

sub run_command_switch_off {
    my $self = shift;
    my $pb_home = $self->home;

    $pb_home->mkpath;
    system("env PERLBREW_PERL= $0 env > " . $pb_home->child ("init"));

    print "\nperlbrew is switched off. Please exit this shell and start a new one to make it effective.\n";
    print "To immediately make it effective, run this line in this terminal:\n\n    exec @{[ $self->env('SHELL') ]}\n\n";
}

sub run_command_env {
    my($self, $name) = @_;

    my %env = $self->perlbrew_env($name);

    my @statements;
    for my $k (sort keys %env) {
        my $v = $env{$k};
        if (defined($v) && $v ne '') {
            $v =~ s/(\\")/\\$1/g;
            push @statements, ["set", $k, $v];
        } else {
            if (exists $ENV{$k}) {
                push @statements, ["unset", $k];
            }
        }
    }

    if ($self->env('SHELL') =~ /(ba|k|z|\/)sh\d?$/) {
        for (@statements) {
            my ($o, $k, $v) = @$_;
            if ($o eq 'unset') {
                print "unset $k\n";
            } else {
                $v =~ s/(\\")/\\$1/g;
                print "export $k=\"$v\"\n";
            }
        }
    } else {
        for (@statements) {
            my ($o, $k, $v) = @$_;
            if ($o eq 'unset') {
                print "unsetenv $k\n";
            } else {
                print "setenv $k \"$v\"\n";
            }
        }
    }
}

sub run_command_symlink_executables {
    my($self, @perls) = @_;
    my $root = $self->root;

    unless (@perls) {
        @perls = map { $_->name } grep { -d $_ && ! -l $_ } $root->perls->list;
    }

    for my $perl (@perls) {
        for my $executable ($root->perls ($perl)->bin->children) {
            my ($name, $version) = $executable =~ m/bin\/(.+?)(5\.\d.*)?$/;
            next unless $version;

			$executable->symlink ($root->perls ($perl)->bin->($name));
			$executable->symlink ($root->perls ($perl)->perl) if $name eq "cperl";
        }
    }
}

sub run_command_install_patchperl {
    my ($self) = @_;
    $self->do_install_program_from_url(
        'https://raw.githubusercontent.com/gugod/patchperl-packing/master/patchperl',
        'patchperl',
        sub {
            my ($body) = @_;
            $body =~ s/\A#!.+?\n/ $self->system_perl_shebang . "\n" /se;
            return $body;
        }
    );
}

sub run_command_install_cpanm {
    my ($self) = @_;
    $self->do_install_program_from_url('https://raw.githubusercontent.com/miyagawa/cpanminus/master/cpanm' => 'cpanm');
}

sub run_command_install_cpm {
    my ($self) = @_;
    $self->do_install_program_from_url('https://raw.githubusercontent.com/skaji/cpm/master/cpm' => 'cpm');
}

sub run_command_self_upgrade {
    my ($self) = @_;
    my $TMPDIR = $ENV{TMPDIR} || "/tmp";
    my $TMP_PERLBREW = App::Perlbrew::Path->new ($TMPDIR, "perlbrew");

    require FindBin;
    unless (-w $FindBin::Bin) {
        die "Your perlbrew installation appears to be system-wide.  Please upgrade through your package manager.\n";
    }

    http_get('https://raw.githubusercontent.com/gugod/App-perlbrew/master/perlbrew', undef, sub {
        my ($body) = @_;

        open my $fh, '>', $TMP_PERLBREW or die "Unable to write perlbrew: $!";
        print $fh $body;
        close $fh;
    });

    chmod 0755, $TMP_PERLBREW;
    my $new_version = qx($TMP_PERLBREW version);
    chomp $new_version;
    if ($new_version =~ /App::perlbrew\/(\d+\.\d+)$/) {
        $new_version = $1;
    } else {
        die "Unable to detect version of new perlbrew!\n";
    }
    if ($new_version <= $VERSION) {
        print "Your perlbrew is up-to-date.\n";
        return;
    }
    system $TMP_PERLBREW, "self-install";
    $TMP_PERLBREW->unlink;
}

sub run_command_uninstall {
    my ($self, $target) = @_;

    unless ($target) {
        $self->run_command_help("uninstall");
        exit(-1);
    }

    my @installed = $self->installed_perls(@_);

    my ($to_delete) = grep { $_->{name} eq $target } @installed;

    die "'$target' is not installed\n" unless $to_delete;

    my @dir_to_delete;
    for (@{$to_delete->{libs}}) {
        push @dir_to_delete, $_->{dir};
    }
    push @dir_to_delete, $to_delete->{dir};

    my $ans = ($self->{yes}) ? "Y": undef;
    if (!defined($ans)) {
        require ExtUtils::MakeMaker;
        $ans = ExtUtils::MakeMaker::prompt("\nThe following perl+lib installation(s) will be deleted:\n\n\t" . join("\n\t", @dir_to_delete) . "\n\n... are you sure ? [y/N]", "N");
    }

    if ($ans =~ /^Y/i) {
        for (@dir_to_delete) {
            print "Deleting: $_\n" unless $self->{quiet};
            App::Perlbrew::Path->new ($_)->rmpath;
            print "Deleted:  $_\n" unless $self->{quiet};
        }
    } else {
        print "\nOK. Not deleting anything.\n\n";
        return;
    }
}

sub run_command_exec {
    my $self = shift;
    my %opts;

    local (@ARGV) = @{$self->{original_argv}};

    Getopt::Long::Configure ('require_order');
    my @command_options = ('with=s', 'halt-on-error');

    $self->parse_cmdline (\%opts, @command_options);
    shift @ARGV; # "exec"
    $self->parse_cmdline (\%opts, @command_options);

    my @exec_with;
    if ($opts{with}) {
        my %installed = map { $_->{name} => $_ } map { ($_, @{$_->{libs}}) } $self->installed_perls;

        my $d = ($opts{with} =~ m/ /) ? qr( +) : qr(,+);
        my @with = grep { $_ } map {
            my ($p, $l) = $self->resolve_installation_name($_);
            $p .= "\@$l" if $l;
            $p;
        } split $d, $opts{with};

        @exec_with = map { $installed{$_} } @with;
    }
    else {
        @exec_with = map { ($_, @{$_->{libs}}) } $self->installed_perls;
    }

    if (0 == @exec_with) {
        print "No perl installation found.\n" unless $self->{quiet};
    }

    my $no_header = 0;
    if (1 == @exec_with) {
        $no_header = 1;
    }

    my $overall_success = 1;
    for my $i ( @exec_with ) {
        next if -l $self->root->perls ($i->{name}); # Skip Aliases
        my %env = $self->perlbrew_env($i->{name});
        next if !$env{PERLBREW_PERL};

        local %ENV = %ENV;
        $ENV{$_} = defined $env{$_} ? $env{$_} : '' for keys %env;
        $ENV{PATH}    = join(':', $env{PERLBREW_PATH}, $ENV{PATH});
        $ENV{MANPATH} = join(':', $env{PERLBREW_MANPATH}, $ENV{MANPATH}||"");
        $ENV{PERL5LIB} = $env{PERL5LIB} || "";

        print "$i->{name}\n==========\n" unless $no_header || $self->{quiet};

        if (my $err = $self->do_system_with_exit_code(@ARGV)) {
            my $exit_code = $err >> 8;
            # return 255 for case when process was terminated with signal, in that case real exit code is useless and weird
            $exit_code = 255 if $exit_code > 255;
            $overall_success = 0;

            unless ($self->{quiet}) {
                print "Command terminated with non-zero status.\n";

                print STDERR "Command [" .
                    join(' ', map { /\s/ ? "'$_'" : $_ } @ARGV) . # trying reverse shell escapes - quote arguments containing spaces
                    "] terminated with exit code $exit_code (\$? = $err) under the following perl environment:\n";
                print STDERR $self->format_info_output;
            }

            $self->do_exit_with_error_code($exit_code) if ($opts{'halt-on-error'});
        }
        print "\n\n" unless $self->{quiet};
    }
    $self->do_exit_with_error_code(1) unless $overall_success;
}

sub run_command_clean {
    my ($self) = @_;
    my $root = $self->root;
    my @build_dirs = $root->build->children;

    for my $dir (@build_dirs) {
        print "Removing $dir\n";
        App::Perlbrew::Path->new ($dir)->rmpath;
    }

    my @tarballs = $root->dists->children;
    for my $file ( @tarballs ) {
        print "Removing $file\n";
        $file->unlink;
    }

    print "\nDone\n";
}

sub run_command_alias {
    my ($self, $cmd, $name, $alias) = @_;

    unless ($cmd) {
        $self->run_command_help("alias");
        exit(-1);
    }

    my $path_name  = $self->root->perls ($name) if $name;
    my $path_alias = $self->root->perls ($alias) if $alias;

    if ($alias && -e $path_alias && !-l $path_alias) {
        die "\nABORT: The installation name `$alias` is not an alias, cannot override.\n\n";
    }

    if ($cmd eq 'create') {
        $self->assert_known_installation($name);

        if ($self->is_installed($alias) && !$self->{force}) {
            die "\nABORT: The installation `${alias}` already exists. Cannot override.\n\n";
        }

        $path_alias->unlink;
        $path_name->symlink ($path_alias);
    }
    elsif ($cmd eq 'delete') {
        $self->assert_known_installation($name);

        unless (-l $path_name) {
            die "\nABORT: The installation name `$name` is not an alias, cannot remove.\n\n";
        }

        $path_name->unlink;
    }
    elsif ($cmd eq 'rename') {
        $self->assert_known_installation($name);

        unless (-l $path_name) {
            die "\nABORT: The installation name `$name` is not an alias, cannot rename.\n\n";
        }

        if (-l $path_alias && !$self->{force}) {
            die "\nABORT: The alias `$alias` already exists, cannot rename to it.\n\n";
        }

        rename($path_name, $path_alias);
    }
    elsif ($cmd eq 'help') {
        $self->run_command_help("alias");
    }
    else {
        die "\nERROR: Unrecognized action: `${cmd}`.\n\n";
    }
}

sub run_command_display_bashrc {
    print BASHRC_CONTENT();
}

sub run_command_display_cshrc {
    print CSHRC_CONTENT();
}

sub run_command_display_installation_failure_message {
    my ($self) = @_;
}

sub run_command_lib {
    my ($self, $subcommand, @args) = @_;

    unless ($subcommand) {
        $self->run_command_help("lib");
        exit(-1);
    }

    my $sub = "run_command_lib_$subcommand";
    if ($self->can($sub)) {
        $self->$sub(@args);
    }
    else {
        print "Unknown command: $subcommand\n";
    }
}

sub run_command_lib_create {
    my ($self, $name) = @_;

    die "ERROR: No lib name\n", $self->run_command_help("lib", undef, 'return_text') unless $name;

    $name = $self->enforce_localib ($name);

    my ($perl_name, $lib_name) = $self->resolve_installation_name($name);

    if (!$perl_name) {
        my ($perl_name, $lib_name) = $self->decompose_locallib ($name);
        die "ERROR: '$perl_name' is not installed yet, '$name' cannot be created.\n";
    }

    my $fullname = $self->compose_locallib ($perl_name, $lib_name);
    my $dir = $self->home->child ("libs", $fullname);

    if (-d $dir) {
        die "$fullname is already there.\n";
    }

    $dir->mkpath;

    print "lib '$fullname' is created.\n"
        unless $self->{quiet};

    return;
}

sub run_command_lib_delete {
    my ($self, $name) = @_;

    die "ERROR: No lib to delete\n", $self->run_command_help("lib", undef, 'return_text') unless $name;

    $name = $self->enforce_localib ($name);

    my ($perl_name, $lib_name) = $self->resolve_installation_name($name);

    my $fullname = $self->compose_locallib ($perl_name, $lib_name);

    my $current  = $self->current_env;

    my $dir = $self->home->child ("libs", $fullname);

    if (-d $dir) {

        if ($fullname eq $current) {
            die "$fullname is currently being used in the current shell, it cannot be deleted.\n";
        }

        $dir->rmpath;

        print "lib '$fullname' is deleted.\n"
            unless $self->{quiet};
    }
    else {
        die "ERROR: '$fullname' does not exist.\n";
    }

    return;
}

sub run_command_lib_list {
    my ($self) = @_;
    my $dir = $self->home->child ("libs");
    return unless -d $dir;

    opendir my $dh, $dir or die "open $dir failed: $!";
    my @libs = grep { !/^\./ && /\@/ } readdir($dh);

    my $current = $self->current_env;
    for (@libs) {
        print $current eq $_ ? "* " : "  ";
        print "$_\n";
    }
}

sub run_command_upgrade_perl {
    my ($self) = @_;

    my $PERL_VERSION_RE = qr/(\d+)\.(\d+)\.(\d+)/;

    my ($current) = grep { $_->{is_current} } $self->installed_perls;

    unless (defined $current) {
        print "no perlbrew environment is currently in use\n";
        exit(1);
    }

    my ($major, $minor, $release);

    if ($current->{version} =~ /^$PERL_VERSION_RE$/) {
        ($major, $minor, $release) = ($1, $2, $3);
    } else {
        print "unable to parse version '$current->{version}'\n";
        exit(1);
    }

    my @available = grep {
        /^perl-$major\.$minor/
    } $self->available_perls;

    my $latest_available_perl = $release;

    foreach my $perl (@available) {
        if ($perl =~ /^perl-$PERL_VERSION_RE$/) {
            my $this_release = $3;
            if ($this_release > $latest_available_perl) {
                $latest_available_perl = $this_release;
            }
        }
    }

    if ($latest_available_perl == $release) {
        print "This perlbrew environment ($current->{name}) is already up-to-date.\n";
        exit(0);
    }

    my $dist_version = "$major.$minor.$latest_available_perl";
    my $dist         = "perl-$dist_version";

    print "Upgrading $current->{name} to $dist_version\n" unless $self->{quiet};
    local $self->{as}        = $current->{name};
    local $self->{dist_name} = $dist;

    require Config ;
    my @d_options = map { '-D' . $flavor{$_}->{d_option}} keys %flavor ;
    my %sub_config = map { $_ => $Config{$_}} grep { /^config_arg\d/} keys %Config ;
    for my $value (values %sub_config) {
        my $value_wo_D = $value;
        $value_wo_D =~ s/^-D//;
        push @{$self->{D}} , $value_wo_D if grep {/$value/} @d_options;
    }

    $self->do_install_release($dist, $dist_version);
}

# Executes the list-modules command.
# This routine launches a new perl instance that, thru
# ExtUtils::Installed prints out all the modules
# in the system. If an argument is passed to the
# subroutine it is managed as a filename
# to which prints the list of modules.
sub run_command_list_modules {
    my ($self, $output_filename) = @_;
    my $class = ref($self) || __PACKAGE__;

    # avoid something that does not seem as a filename to print
    # output to...
    undef $output_filename if (! scalar($output_filename));

    my $name = $self->current_env;
    if (-l (my $path = $self->root->perls ($name))) {
        $name = $path->readlink->basename;
    }

    my $app = $class->new(
        qw(--quiet exec --with),
        $name,
        'perl',
        '-MExtUtils::Installed',
        '-le',
        sprintf('BEGIN{@INC=grep {$_ ne q!.!} @INC}; %s print {%s} $_ for ExtUtils::Installed->new->modules;',
                $output_filename ? sprintf('open my $output_fh, \'>\', "%s"; ', $output_filename) : '',
                $output_filename ? '$output_fh' : 'STDOUT')
    );

    $app->run;
}

sub resolve_installation_name {
    my ($self, $name) = @_;
    die "App::perlbrew->resolve_installation_name requires one argument." unless $name;

    my ($perl_name, $lib_name) = $self->decompose_locallib ($name);
    $perl_name = $name unless $lib_name;
    $perl_name ||= $self->current_perl;

    if (!$self->is_installed($perl_name)) {
        if ($self->is_installed("perl-${perl_name}") ) {
            $perl_name = "perl-${perl_name}";
        }
        else {
            return undef;
        }
    }

    return wantarray ? ($perl_name, $lib_name) : $perl_name;
}

# Implementation of the 'clone-modules' command.
#
# This method accepts a destination and source installation
# of Perl to clone modules from and into.
# For instance calling
# $app->run_command_clone_modules($perl_a, $perl_b);
# installs all modules that have been installed on Perl A
# to the instance of Perl B.
# The source instance is optional, that is if the method
# is invoked with a single argument, the currently
# running instance is used as source. Therefore the
# two following calls are the same:
#
# $app->run_command_clone_modules( $self->current_perl, $perl_b );
# $app->run_command_clone_modules( $perl_b );
#
# Of course, both Perl installation must exist on this
# perlbrew enviroment.
#
# The method extracts the modules installed on the source Perl
# instance and put them on a temporary file, such file is then
# passed to another instance of the application to
# execute cpanm on it. The final result is the installation
# of source modules into the destination instance.
sub run_command_clone_modules {
    my $self = shift;

    # default to use the currently installation
    my ( $dst_perl, $src_perl );

    # the first argument is the destination, the second
    # optional argument is the source version, default
    # to use the current installation
    $dst_perl = pop || $self->current_env;
    $src_perl = pop || $self->current_env;


    # check source and destination do exist
    undef $src_perl if (! $self->resolve_installation_name($src_perl));
    undef $dst_perl if (! $self->resolve_installation_name($dst_perl));

    if ( ! $src_perl
         || ! $dst_perl
         || $src_perl eq $dst_perl ){
        # cannot understand from where to where or
        # the user did specify the same versions
        $self->run_command_help('clone-modules');
        exit(-1);
    }


    # I need to run an application to do the module listing.
    # and get the result back so to handle it and pass
    # to the exec subroutine. The solution I found so far
    # is to store the result in a temp file (the list_modules
    # uses a sub-perl process, so there is no way to pass a
    # filehandle or something similar).
    my $class = ref($self);
    require File::Temp;
    my $modules_fh = File::Temp->new;

    # list all the modules and place them in the output file
    my $src_app = $class->new(
        qw(--quiet exec --with),
        $src_perl,
        'perl',
        '-MExtUtils::Installed',
        '-le',
        sprintf('BEGIN{@INC=grep {$_ ne q!.!} @INC}; open my $output_fh, ">", "%s"; print {$output_fh} $_ for ExtUtils::Installed->new->modules;',
                $modules_fh->filename )
        );

    $src_app->run;

    # here I should have the list of modules into the
    # temporary file name, so I can ask the destination
    # perl instance to install such list
    $modules_fh->close;
    open $modules_fh, '<', $modules_fh->filename;
    chomp(my @modules_to_install = <$modules_fh>);
    $modules_fh->close;
    die "\nNo modules installed on $src_perl !\n" if (! @modules_to_install);
    print "\nInstalling $#modules_to_install modules from $src_perl to $dst_perl ...\n";

    # create a new application to 'exec' the 'cpanm'
    # with the specified module list

    my $app = $class->new(
        qw(--quiet exec --with),
        $dst_perl,
        'cpanm',
        @modules_to_install
        );

    $app->run;

}

sub format_info_output
{
    my ($self, $module) = @_;

    my $out = '';

    $out .= "Current perl:\n";
    if ($self->current_perl) {
        $out .= "  Name: " . $self->current_env . "\n";
        $out .= "  Path: " . $self->installed_perl_executable($self->current_perl) . "\n";
        $out .= "  Config: " . $self->configure_args($self->current_perl) . "\n";
        $out .= join('', "  Compiled at: ", (map {
            /  Compiled at (.+)\n/ ? $1 : ()
        } `@{[ $self->installed_perl_executable($self->current_perl) ]} -V`), "\n");
    }
    else {
        $out .= "Using system perl." . "\n";
        $out .= "Shebang: " . $self->system_perl_shebang . "\n";
    }

    $out .= "\nperlbrew:\n";
    $out .= "  version: " . $self->VERSION . "\n";
    $out .= "  ENV:\n";
    for(map{"PERLBREW_$_"}qw(ROOT HOME PATH MANPATH)) {
        $out .= "    $_: " . ($self->env($_)||"") . "\n";
    }

    if ($module) {
        my $code = qq{eval "require $module" and do { (my \$f = "$module") =~ s<::></>g; \$f .= ".pm"; print "$module\n  Location: \$INC{\$f}\n  Version: " . ($module->VERSION ? $module->VERSION : "no VERSION specified" ) } or do { print "$module could not be found, is it installed?" } };
        $out .= "\nModule: ".$self->do_capture($self->installed_perl_executable($self->current_perl), "-le", $code);
    }

    $out;
}

sub run_command_info {
    my ($self) = shift;
    print $self->format_info_output(@_);
}

sub BASHRC_CONTENT() {
    return "export PERLBREW_SHELLRC_VERSION=$VERSION\n" .
           (exists $ENV{PERLBREW_ROOT} ? "export PERLBREW_ROOT=$PERLBREW_ROOT\n" : "") . "\n" . <<'RC';

__perlbrew_reinit() {
    if [[ ! -d "$PERLBREW_HOME" ]]; then
        mkdir -p "$PERLBREW_HOME"
    fi

    [ -f "$PERLBREW_HOME/init" ] && rm "$PERLBREW_HOME/init"
    echo '# DO NOT EDIT THIS FILE' > "$PERLBREW_HOME/init"
    command perlbrew env $1 | \grep PERLBREW_ >> "$PERLBREW_HOME/init"
    . "$PERLBREW_HOME/init"
    __perlbrew_set_path
}

__perlbrew_purify () {
    local path patharray outsep
    IFS=: read -r${BASH_VERSION+a}${ZSH_VERSION+A} patharray <<< "$1"
    for path in "${patharray[@]}" ; do
        case "$path" in
            (*"$PERLBREW_HOME"*) ;;
            (*"$PERLBREW_ROOT"*) ;;
            (*) printf '%s' "$outsep$path" ; outsep=: ;;
        esac
    done
}

__perlbrew_set_path () {
    export MANPATH=$PERLBREW_MANPATH${PERLBREW_MANPATH:+:}$(__perlbrew_purify "$(manpath 2>/dev/null)")
    export PATH=${PERLBREW_PATH:-$PERLBREW_ROOT/bin}:$(__perlbrew_purify "$PATH")
    hash -r
}

__perlbrew_set_env() {
    local code
    code="$($perlbrew_command env $@)" || return $?
    eval "$code"
}

__perlbrew_activate() {
    [[ -n $(alias perl 2>/dev/null) ]] && unalias perl 2>/dev/null

    if [[ -n "$PERLBREW_PERL" ]]; then
        __perlbrew_set_env "$PERLBREW_PERL${PERLBREW_LIB:+@}$PERLBREW_LIB"
    fi

    __perlbrew_set_path
}

__perlbrew_deactivate() {
    __perlbrew_set_env
    unset PERLBREW_PERL
    unset PERLBREW_LIB
    __perlbrew_set_path
}

perlbrew () {
    local exit_status
    local short_option
    export SHELL

    if [[ $1 == -* ]]; then
        short_option=$1
        shift
    else
        short_option=""
    fi

    case $1 in
        (use)
            if [[ -z "$2" ]] ; then
                echo -n "Currently using ${PERLBREW_PERL:-system perl}"
                [ -n "$PERLBREW_LIB" ] && echo -n "@$PERLBREW_LIB"
                echo
            else
                __perlbrew_set_env "$2" && { __perlbrew_set_path ; true ; }
                exit_status="$?"
            fi
            ;;

        (switch)
              if [[ -z "$2" ]] ; then
                  command perlbrew switch
              else
                  perlbrew use $2 && { __perlbrew_reinit $2 ; true ; }
                  exit_status=$?
              fi
              ;;

        (off)
            __perlbrew_deactivate
            echo "perlbrew is turned off."
            ;;

        (switch-off)
            __perlbrew_deactivate
            __perlbrew_reinit
            echo "perlbrew is switched off."
            ;;

        (*)
            command perlbrew $short_option "$@"
            exit_status=$?
            ;;
    esac
    hash -r
    return ${exit_status:-0}
}

[[ -z "$PERLBREW_ROOT" ]] && export PERLBREW_ROOT="$HOME/perl5/perlbrew"
[[ -z "$PERLBREW_HOME" ]] && export PERLBREW_HOME="$HOME/.perlbrew"

if [[ ! -n "$PERLBREW_SKIP_INIT" ]]; then
    if [[ -f "$PERLBREW_HOME/init" ]]; then
        . "$PERLBREW_HOME/init"
    fi
fi

perlbrew_bin_path="${PERLBREW_ROOT}/bin"
if [[ -f $perlbrew_bin_path/perlbrew ]]; then
    perlbrew_command="$perlbrew_bin_path/perlbrew"
else
    perlbrew_command="perlbrew"
fi
unset perlbrew_bin_path

__perlbrew_activate

RC

}

sub BASH_COMPLETION_CONTENT() {
    return <<'COMPLETION';
if [[ -n ${ZSH_VERSION-} ]]; then
    autoload -U +X bashcompinit && bashcompinit
fi

export PERLBREW="command perlbrew"
_perlbrew_compgen()
{
    COMPREPLY=( $($PERLBREW compgen $COMP_CWORD ${COMP_WORDS[*]}) )
}
complete -F _perlbrew_compgen perlbrew
COMPLETION
}

sub PERLBREW_FISH_CONTENT {
    return "set -x PERLBREW_SHELLRC_VERSION $VERSION\n" . <<'END';

function __perlbrew_reinit
    if not test -d "$PERLBREW_HOME"
        mkdir -p "$PERLBREW_HOME"
    end

    echo '# DO NOT EDIT THIS FILE' > "$PERLBREW_HOME/init"
    command perlbrew env $argv[1] | \grep PERLBREW_ >> "$PERLBREW_HOME/init"
    __source_init
    __perlbrew_set_path
end

function __perlbrew_set_path
    set -l MANPATH_WITHOUT_PERLBREW (perl -e 'print join ":", grep { index($_, $ENV{PERLBREW_HOME}) < 0 } grep { index($_, $ENV{PERLBREW_ROOT}) < 0 } split/:/,qx(manpath 2> /dev/null);')

    if test -n "$PERLBREW_MANPATH"
        set -l PERLBREW_MANPATH $PERLBREW_MANPATH":"
        set -x MANPATH {$PERLBREW_MANPATH}{$MANPATH_WITHOUT_PERLBREW}
    else
        set -x MANPATH $MANPATH_WITHOUT_PERLBREW
    end

    set -l PATH_WITHOUT_PERLBREW (eval $perlbrew_command display-pristine-path | perl -pe'y/:/ /')

    # silencing stderr in case there's a non-existent path in $PATH (see GH#446)
    if test -n "$PERLBREW_PATH"
        set -x PERLBREW_PATH (echo $PERLBREW_PATH | perl -pe 'y/:/ /' )
        eval set -x PATH $PERLBREW_PATH $PATH_WITHOUT_PERLBREW 2> /dev/null
    else
        eval set -x PATH $PERLBREW_ROOT/bin $PATH_WITHOUT_PERLBREW 2> /dev/null
    end
end

function __perlbrew_set_env
    set -l code (eval $perlbrew_command env $argv | perl -pe 's/^(export|setenv)/set -xg/; s/=/ /; s/^unset[env]*/set -eug/; s/$/;/; y/:/ /')

    if test -z "$code"
        return 0;
    else
        eval $code
    end
end

function __perlbrew_activate
    functions -e perl

    if test -n "$PERLBREW_PERL"
        if test -z "$PERLBREW_LIB"
            __perlbrew_set_env $PERLBREW_PERL
        else
            __perlbrew_set_env $PERLBREW_PERL@$PERLBREW_LIB
        end
    end

    __perlbrew_set_path
end

function __perlbrew_deactivate
    __perlbrew_set_env
    set -x PERLBREW_PERL
    set -x PERLBREW_LIB
    set -x PERLBREW_PATH
    __perlbrew_set_path
end

function perlbrew

    test -z "$argv"
    and echo "    Usage: perlbrew <command> [options] [arguments]"
    and echo "       or: perlbrew help"
    and return 1

    switch $argv[1]
        case use
            if test ( count $argv ) -eq 1
                if test -z "$PERLBREW_PERL"
                    echo "Currently using system perl"
                else
                    echo "Currently using $PERLBREW_PERL"
                end
            else
                __perlbrew_set_env $argv[2]
                if test "$status" -eq 0
                    __perlbrew_set_path
                end
            end

        case switch
            if test ( count $argv ) -eq 1
                command perlbrew switch
            else
                perlbrew use $argv[2]
                if test "$status" -eq 0
                    __perlbrew_reinit $argv[2]
                end
            end

        case off
            __perlbrew_deactivate
            echo "perlbrew is turned off."

        case switch-off
            __perlbrew_deactivate
            __perlbrew_reinit
            echo "perlbrew is switched off."

        case '*'
            command perlbrew $argv
    end
end

function __source_init
    perl -pe's/^(export|setenv)/set -xg/; s/=/ /; s/$/;/;' "$PERLBREW_HOME/init" | source
end

if test -z "$PERLBREW_ROOT"
    set -x PERLBREW_ROOT "$HOME/perl5/perlbrew"
end

if test -z "$PERLBREW_HOME"
    set -x PERLBREW_HOME "$HOME/.perlbrew"
end

if test -z "$PERLBREW_SKIP_INIT" -a -f "$PERLBREW_HOME/init"
    __source_init
end

set perlbrew_bin_path "$PERLBREW_ROOT/bin"

if test -f "$perlbrew_bin_path/perlbrew"
    set perlbrew_command "$perlbrew_bin_path/perlbrew"
else
    set perlbrew_command perlbrew
end

set -e perlbrew_bin_path

__perlbrew_activate

## autocomplete stuff #############################################

function __fish_perlbrew_needs_command
  set cmd (commandline -opc)
  if test (count $cmd) -eq 1 -a $cmd[1] = 'perlbrew'
    return 0
  end
  return 1
end

function __fish_perlbrew_using_command
  set cmd (commandline -opc)
  if test (count $cmd) -gt 1
    if [ $argv[1] = $cmd[2] ]
      return 0
    end
  end
end

for com in (perlbrew help | perl -ne'print lc if s/^COMMAND:\s+//')
    complete -f -c perlbrew -n '__fish_perlbrew_needs_command' -a $com
end

for com in switch use;
    complete -f -c perlbrew -n "__fish_perlbrew_using_command $com" \
        -a '(perlbrew list | perl -pe\'s/\*?\s*(\S+).*/$1/\')'
end

END
}

sub CSH_WRAPPER_CONTENT {
    return <<'WRAPPER';
set perlbrew_exit_status=0

if ( $1 =~ -* ) then
    set perlbrew_short_option=$1
    shift
else
    set perlbrew_short_option=""
endif

switch ( $1 )
    case use:
        if ( $%2 == 0 ) then
            if ( $?PERLBREW_PERL == 0 ) then
                echo "Currently using system perl"
            else
                if ( $%PERLBREW_PERL == 0 ) then
                    echo "Currently using system perl"
                else
                    echo "Currently using $PERLBREW_PERL"
                endif
            endif
        else
            set perlbrew_line_count=0
            foreach perlbrew_line ( "`\perlbrew env $2`" )
                eval $perlbrew_line
                @ perlbrew_line_count++
            end
            if ( $perlbrew_line_count == 0 ) then
                set perlbrew_exit_status=1
            else
                source "$PERLBREW_ROOT/etc/csh_set_path"
            endif
        endif
        breaksw

    case switch:
        if ( $%2 == 0 ) then
            \perlbrew switch
        else
            perlbrew use $2 && source $PERLBREW_ROOT/etc/csh_reinit $2
        endif
        breaksw

    case off:
        unsetenv PERLBREW_PERL
        foreach perlbrew_line ( "`\perlbrew env`" )
            eval $perlbrew_line
        end
        source $PERLBREW_ROOT/etc/csh_set_path
        echo "perlbrew is turned off."
        breaksw

    case switch-off:
        unsetenv PERLBREW_PERL
        source $PERLBREW_ROOT/etc/csh_reinit ''
        echo "perlbrew is switched off."
        breaksw

    default:
        \perlbrew $perlbrew_short_option $argv
        set perlbrew_exit_status=$?
        breaksw
endsw
rehash
exit $perlbrew_exit_status
WRAPPER
}

sub CSH_REINIT_CONTENT {
    return <<'REINIT';
if ( ! -d "$PERLBREW_HOME" ) then
    mkdir -p "$PERLBREW_HOME"
endif

echo '# DO NOT EDIT THIS FILE' >! "$PERLBREW_HOME/init"
\perlbrew env $1 >> "$PERLBREW_HOME/init"
source "$PERLBREW_HOME/init"
source "$PERLBREW_ROOT/etc/csh_set_path"
REINIT
}

sub CSH_SET_PATH_CONTENT {
    return <<'SETPATH';
unalias perl

if ( $?PERLBREW_PATH == 0 ) then
    setenv PERLBREW_PATH "$PERLBREW_ROOT/bin"
endif

setenv PATH_WITHOUT_PERLBREW `perl -e 'print join ":", grep { index($_, $ENV{PERLBREW_ROOT}) } split/:/,$ENV{PATH};'`
setenv PATH "${PERLBREW_PATH}:${PATH_WITHOUT_PERLBREW}"

setenv MANPATH_WITHOUT_PERLBREW `perl -e 'print join ":", grep { index($_, $ENV{PERLBREW_ROOT}) } split/:/,qx(manpath 2> /dev/null);'`
if ( $?PERLBREW_MANPATH == 1 ) then
    setenv MANPATH ${PERLBREW_MANPATH}:${MANPATH_WITHOUT_PERLBREW}
else
    setenv MANPATH ${MANPATH_WITHOUT_PERLBREW}
endif
SETPATH
}

sub CSHRC_CONTENT {
    return "setenv PERLBREW_SHELLRC_VERSION $VERSION\n\n" . <<'CSHRC';

if ( $?PERLBREW_HOME == 0 ) then
    setenv PERLBREW_HOME "$HOME/.perlbrew"
endif

if ( $?PERLBREW_ROOT == 0 ) then
    setenv PERLBREW_ROOT "$HOME/perl5/perlbrew"
endif

if ( $?PERLBREW_SKIP_INIT == 0 ) then
    if ( -f "$PERLBREW_HOME/init" ) then
        source "$PERLBREW_HOME/init"
    endif
endif

if ( $?PERLBREW_PATH == 0 ) then
    setenv PERLBREW_PATH "$PERLBREW_ROOT/bin"
endif

source "$PERLBREW_ROOT/etc/csh_set_path"
alias perlbrew 'source $PERLBREW_ROOT/etc/csh_wrapper'
CSHRC

}

sub append_log {
    my ($self, $message) = @_;
    my $log_handler;
    open($log_handler, '>>', $self->{log_file})
        or die "Cannot open log file for appending: $!";
    print $log_handler "$message\n";
    close($log_handler);
}

sub INSTALLATION_FAILURE_MESSAGE {
    my ($self) = @_;
    return <<FAIL;
Installation process failed. To spot any issues, check

  $self->{log_file}

If some perl tests failed and you still want to install this distribution anyway,
do:

  (cd $self->{dist_extracted_dir}; make install)

You might also want to try upgrading patchperl before trying again:

  perlbrew install-patchperl

Generally, if you need to install a perl distribution known to have minor test
failures, do one of these command to avoid seeing this message

  perlbrew --notest install $self->{dist_name}
  perlbrew --force install $self->{dist_name}

FAIL


    sub PAUSE_PGP_KEYRING {
        require MIME::Base64;
        return MIME::Base64::decode_base64(<<'PGP')
mQGiBD4+cJARBACxOByY0SJBBuJoFrH2hoqRFny423gY6V3jq1uTgGY/PPaxP+Sqr3RzxPct
4vJcsoo48pwBsMHLrWfORq26zb6eKgmMq/CQo2gzaRbeRxCi3ke4KBmuaREi6RjaZSU94yAB
tDmspUBrpYV8zfZMv5ZIQlg9W1Tu66BFOUrrNeDpKwCgosCp9dtNAMhHkzxs8UJH5i3Uzb0D
/0VLoAE8sOfUXqjc38rxiHuGBFSNC70Ih4mzGUCJMGT4z1X3K6uUawnXMoc8XqPaYnEgOzzt
Mymydtr+urjUwcGnuXDSpV6nulE5irxhzlikSTJy/42QzTMcrdRynffmJo9PRgymMI8GgWaY
G5g3zzGAhi5BA6G8JKfC93IVxiRPBACXJpLBYQljqJY9UDNJuq8nHhKiWHBXdZzrC3LM0FSF
3PKuP/ugc+KBIKXmclNPNFKla/SRbH6dMHsGIy8wnGPI5AtTS0roNQrttv3/ghRT7+OKXrGm
BxZ/KHVrv3PVgiRA5MDr1mIsovfuc9WQnFu2TkgnN/F3pDcrVVSi5b+rZLQzUEFVU0UgQmF0
Y2ggU2lnbmluZyBLZXkgMjAwMyA8cGF1c2VAcGF1c2UucGVybC5vcmc+iEYEEBECAAYFAkRg
ouoACgkQi9gubzC5S1z/jgCeME8EOFOfLH3VjZAAN4BI/UN9+NEAn0mi5nuCYYdeRqaZY9Sf
mZGNkTNLiEYEEBECAAYFAkdcDv8ACgkQFfjlw8DQnmpG7ACeO0epXdwr9kaMQBvtp0pD33+9
UPAAnArApAeogPV0uecsCg97T20HQntiiEYEEBECAAYFAkl8FPcACgkQ7IA58KMXwV31KwCg
zANGg0fEkmkA5bIuRd8rEfmxSnoAnRxw3udIJOxqS2NDxAUHNM696BVFiEYEEBECAAYFAkob
/E0ACgkQK44xRkGJ7Sf/2ACfe0661HIJaOIPGdcputsmS9wN3X4An0e8oliNmpA+RXDfN3ZV
T+0NW6UaiEYEEBECAAYFAkuMSNYACgkQNK6uszzRsMwGWQCgyjLm0qoD+86+JOCQEPS36jFt
jGUAnj0uFPy2A75Zx+iSPng/+WtOzIc7iEYEERECAAYFAknLgNoACgkQNswVpONZZfxukwCf
cJOmBOzEk52KjxfkJ5CvOKLPUbUAoIqwRCU7hTcQiq6JHCxwPEgd/oGkiEYEExECAAYFAkqY
be0ACgkQ6dZ+Kt5Bchb6HACfTy9uMRRSDIrscbv8fqKhXjVgBM8An3s+ImDx/LzholCxdxXi
pFlq/SFKiEkEEBECAAkFAkQmiMgCBwAACgkQBluKcF8+Xov8lQCfadx0mU5FNU72DWOR8NfS
L3d521MAn1LLH+GrJa4Wx7RT3vfg5GqWkEdoiEkEEBECAAkFAkQmiM0CBwAACgkQBluKcF8+
XoswswCfYMlq4vZrnM2/4S+0MUHmHZTkJHEAn04zh4ZQvtJ/uH4fgWe58sUreCpPiEkEEBEC
AAkFAkfvvA4CBwAACgkQX9tx4S9YpStxeQCeM+5SjYw9vT2ofmFlMsCo+L9c+50AnA+laELg
+fJJWRMoV2796vdV0Rv+iEkEEBECAAkFAkfvvA4CBwAACgkQX9tx4S9YpSt3QgCeOhqu0hDx
3a2alIX0e/levEoN3oUAnAiY29G2vJHenK8z2v1oh5xr3DyniEwEExECAAwFAkCpmDoFgwFX
P1YACgkQGFnQH2d7oeygtwCfXtQUrPwRDPDOpDOIicSRJGGQyFgAoI1GtaAJf5dVbVMrmBD9
8KsOh/odiEwEExECAAwFAkCpmIwFgwFXPwQACgkQgcL36+ITtpIn6ACfX6DEb8xYAbbs0mHB
Tqui7yolOB4An1tFxYTuqBlBFr6UX/DBa+dmvKv0iEwEExECAAwFAkCpmMsFgwFXPsUACgkQ
a3Ds2V3D9HNKmgCfatVdvWiRdTflqhgjik+lCr9pCNgAn0FaNjIYck2s+Mk5c1Jr7dOg6Y8o
iFsEEBECABsFAkPB0/cDBQJ4EIY8W14+XStbQC5dXCo+JAAACgkQhuayTZJYT+HJ5gCg1riu
gJbBgtw4fLb/X0dsZ4vrJWkAn3UHqGcUghBmxPs+5BpHbRiHJvijiF0EEBECAB0WIQRZHhhU
cL58V8z0UW2abZJij/3JQgUCWKbPhwAKCRCabZJij/3JQuyJAKCE7BkIc1vgM1hMK5Sefscq
yKAxcQCcDAU8oX3KS/VRbjr4X5OyQAHvR96IXwQTEQIAHwQLBwMCAxUCAwMWAgECHgECF4AF
AkHhoF8FCQengc8ACgkQMo2oZ0UPiexlVACeL1liZ5vBd8702AHOgMeTuD7OSIsAn2JNGB32
2zrZ42RJ33OKupFLlFuLiF8EExECAB8ECwcDAgMVAgMDFgIBAh4BAheABQJFmYJbBQkMDBhL
AAoJEDKNqGdFD4nskScAoIxv869VyYWRtTvs9UXUVWwCmuxZAKCdM/TdwFg4b/PiRltNJ/vw
LMuTVIhfBBMRAgAfBAsHAwIDFQIDAxYCAQIeAQIXgAUCSXjfkAUJD850gAAKCRAyjahnRQ+J
7IacAJ9Aw4aa273LSPYRsQUO6mGQ2cw+dACdGbzUouIRV4BLV4othnzxIZR8jm6IXwQTEQIA
HwQLBwMCAxUCAwMWAgECHgECF4AFAk1z88QFCROSKWgACgkQMo2oZ0UPiey5dACgibzP80/E
7hHL1SrxwKgbMTeBv6kAnjn496NYgmZTaMKRrSpz3Vh7Zo7XiF8EExECAB8ECwcDAgMVAgMD
FgIBAh4BAheABQJRhTQUBQkXVFAEAAoJEDKNqGdFD4nsLTYAn2vk+lhTvBwSpqnEai9nhyLC
3Vi7AKCih0cbVa0nPNDwf1W8PcpBtwVAs4hfBBMRAgAfBAsHAwIDFQIDAxYCAQIeAQIXgAUC
VNd2rQUJGxfznQAKCRAyjahnRQ+J7FgSAKCc3/REXSWkbh3Gi7/01O7lqrc5LwCgkBwa9JtL
wbCRKC7YLyLGlDE+/T2IXwQTEQIAHwQLBwMCAxUCAwMWAgECHgECF4AFAlk988AFCR7ZpTAA
CgkQMo2oZ0UPiez6IwCfZRC7MdrvExBAA4shS8GUTFuVfzAAn2aKDUILX1yn47MMSM9JtqHb
tJ70iF8EExECAB8FAj4+cJAFCQPCZwAECwcDAgMVAgMDFgIBAh4BAheAAAoJEDKNqGdFD4ns
d4sAn3gYvr37VkUycx61wm5t4BoSO904AJ9dkl/zU5BbDnXEPKk0FNWFSnwnxYhkBBMRAgAk
AhsDBgsJCAcDAgMVAgMDFgIBAh4BAheABQJFmYJbBQkMDBhLAAoJEDKNqGdFD4ns79IAnj21
IeZSt2NoOO1/g+vD5tqOcbzUAJ478n1mnym4Q2N3TTT3rsnnedcdvohnBBMRAgAfBQI+PnCQ
BQkDwmcABAsHAwIDFQIDAxYCAQIeAQIXgAASCRAyjahnRQ+J7AdlR1BHAAEBd4sAn3gYvr37
VkUycx61wm5t4BoSO904AJ9dkl/zU5BbDnXEPKk0FNWFSnwnxYkBHAQQAQIABgUCWvSqdgAK
CRAgVoctjWQSAClZB/9/Ygl3t8FINdAjw7Q1o6VE7sgFyJj2tSy/F9ducbyYX/hzN/VsX8KL
uLkmRiL4iGE1433KiHC4iiLBZGCyP+Ai/9lxu2qzf3BljRkM8h16yrsnTt2AAaP2Nt0rLxtH
9vxLbeWEMyeIwGyvW5dMU5WThCH0cMMMx6+EMjzIMQzW/L+ORqAD2DiVeimSEXlMnUg+0TqG
aLIAJjrS5Wz9hWdXa4PFqkngXogN9qUiDk5p4dKQPCItg2yJs17TuLjKJVhnToha3uV/d147
zZQPH0GxAI5Y8UJg4ggMnwRqRgYoV43ST36suohKkkup+7ekul/Ck9YlcnVMIL2tmHKiIT8I
iQEcBBIBCAAGBQJZW5ixAAoJECNFGxB6oDlBi9MH/3O4TALf0P5yfnKjuIaE7lawAAz5cEkO
+xnQExtSLWUCeIWPE0quxHHqO9Fj9ZVDMwz70wrH0o7V/LLA7PHXm4dR9QxDeao0lvNVsZcX
jAd/7pWTEWgnu/ccpHCQcQ1+jKf5XgvhAr2OcGZez+soHQL5O6FX3eXIFBqctueyyTO51Q5G
sKsnDNxCLD+pDKkJ824iCmdAMM1LGhnbN4VINwXCyJevZ8hRK7zeDDGBePWakPhIgq7SLOwT
9oqbgzztVMeEL0i3uvGPtymWbmuIJheguOsk1TRQoEx0fOEYGqxBfYjI2k6uMrwTElZSAHkD
B8MUjfslQRzhgbn9E9fbVWmJAiIEEAECAAwFAkF/KkwFgwCBrUQACgkQquPmzmahRGgMBQ/+
KTuO2plAFVOz+Qw90F16Ujg5aiwem3OFHNzHxwozbprQOYT5ZNuVV9ZAL4wTwTTVmkkQtJcA
S+PV9g9uRkMGilo1tLBCqidFLK+mgbboUKy5RmBzCCfBYcMRwKmRRaN724NF0c0RURLNMQDA
xakjopcGluh9M1B8HY9FjBcjz7tD0Xmq/OLpagf0wQhqeXQVQGhwbuIFnIxxAqHLBV1vMLan
KLMv8n6dl3pvKqKXcCqWGbx9UN6LochYHjWl7qftXTWFNMb+NIo5H6Wlgfw/ESFEbZjB7Xnl
vACyuKBdsB0n1IAckYHp2EnpXtWd0e73rviN5ssNFJLDs1/Ccc/woViRiZMoMaWuB4MVLoWP
6mbF44C5C6kwq1dZPPiPYXJTI1/q4wtoPyCl36ruYQ8wPwzaNiiEOTjjVJLiXpGQuWZNcyrF
2N6Y5/FMF5Nri36l1kiTk9Cj2Rgoz6OFGyiWIka2PWISIho2/gjHgmhjjP8/k293w76GNbv4
qguoQbmCavXS8GnrNSPJt4mbt19BFQ6ZEDgmK652+m8um1kWVgKPgWJ2lF6/mDcSmpDId4CQ
MQls5brBuG+Vfn+wH3mnJC80FEaqA7PlzaYZgIWVL/O5gaSTUz0UnlTdS38E28usYRO0avef
ggbYHf35sBjdlTfQKWy4cL3O6swdqNm0jH60M1BBVVNFIEJhdGNoIFNpZ25pbmcgS2V5IDIw
MDUgPHBhdXNlQHBhdXNlLnBlcmwub3JnPohGBBARAgAGBQJEYKLoAAoJEIvYLm8wuUtc30QA
oK2czUefYahtYW+TbtIXdhUdW+fOAJwNi0bJ8trCaZNOgCUQ9LrcfYI17IhGBBARAgAGBQJH
XA7/AAoJEBX45cPA0J5q9UwAn3xJ7SdXCCkYIRedhOPbST7HSqSaAJ92GqcSJ8sXF/j+NJoz
TCHRM9q1oYhGBBARAgAGBQJJfBT3AAoJEOyAOfCjF8FdMEwAn2tOIVnkIVy2adN7BLWuMKW/
RaVAAKDbUwhKGwwOmhbkzykdFT89OAquD4hGBBARAgAGBQJKG/xNAAoJECuOMUZBie0n+1UA
oIxu/zwj0oj1DoryyXy7TeKiVxbrAJ4lBA2V5QHfahrtnizRHQeBf3TavIhGBBARAgAGBQJL
jEjWAAoJEDSurrM80bDMdDQAn2ldZHCT1AleaF8mkXkUcW+s2rCIAKCAkLuM9aEVhj30wPms
xaIogIz40ohGBBERAgAGBQJJy4DaAAoJEDbMFaTjWWX8tQMAn3BvNmP0E57Nr3MgM8+N/3J3
ACfTAJ41hJiaKCPyCt+bERGo+4bazKvWEohGBBMRAgAGBQJKmG3tAAoJEOnWfireQXIWRBEA
n30xKJFU1JOkf/VWPs+jBVmr2JS1AKCIPIf2PgpVlJ9nNlE682w7hs0lXYhJBBARAgAJBQJE
JojIAgcAAAoJEAZbinBfPl6L/JUAn2ncdJlORTVO9g1jkfDX0i93edtTAJ9Syx/hqyWuFse0
U9734ORqlpBHaIhJBBARAgAJBQJH77wOAgcAAAoJEF/bceEvWKUra8YAoInG8bVs+rH/8UuU
Kso0c4gJef7bAKC42ez9cFFlD58mjf69FlTHZZKXZohbBBARAgAbBQJDwdPxAwUCeBCGPFte
Pl0rW0AuXVwqPiQAAAoJEIbmsk2SWE/h0twAn3UcQ3Xg2AyOmGBMnUOdgpNH28CRAJ9rSQBX
nF5DqSt1qv9Dab2asqKfO4hdBBARAgAdFiEEWR4YVHC+fFfM9FFtmm2SYo/9yUIFAlimz4cA
CgkQmm2SYo/9yULqPgCdEH1cd7zSv94QJFfsP23dy47YkkEAnRZ7W0NWBvQFUgwSB3tHC73N
OMV+iGQEExECACQCGwMGCwkIBwMCAxUCAwMWAgECHgECF4AFAkWZglsFCQwMGEsACgkQMo2o
Z0UPiezv0gCePbUh5lK3Y2g47X+D68Pm2o5xvNQAnjvyfWafKbhDY3dNNPeuyed51x2+iGQE
ExECACQCGwMGCwkIBwMCAxUCAwMWAgECHgECF4AFAkl435AFCQ/OdIAACgkQMo2oZ0UPiexF
MwCfVlBFOB7K/EyM/mMWeKHfE6qaYtAAnApuQ3l7nZNpTmwUpF2DusvWD0B3iGQEExECACQC
GwMGCwkIBwMCAxUCAwMWAgECHgECF4AFAk1z88QFCROSKWgACgkQMo2oZ0UPiewObACfdvGx
yM20aXherg1hgqLL3xheTOkAmweOm4ZOYkaXnHX1Zy6BtO7fWP4eiGQEExECACQCGwMGCwkI
BwMCAxUCAwMWAgECHgECF4AFAlGFNBQFCRdUUAQACgkQMo2oZ0UPiexZcQCeK+CSOoWlXSZV
eYtlhzJUMS4SiDAAoJEZMIoJax40ZhK6HGIFBYm6lI/diGQEExECACQCGwMGCwkIBwMCAxUC
AwMWAgECHgECF4AFAlTXdq0FCRsX850ACgkQMo2oZ0UPiezK6wCghdqjSqz+epsIzfKmvJvv
/4DlllAAn2bsuoCoVJTt0f3ZtgG0RR6J0f42iGQEExECACQCGwMGCwkIBwMCAxUCAwMWAgEC
HgECF4AFAlk988AFCR7ZpTAACgkQMo2oZ0UPiezwJgCePIrwUH1iVY3TJzOgnPqp4IWjZYgA
nRffgcXRHUGT0ijyW92/b/KStcW0iGQEExECACQFAkHhoIQCGwMFCQengc8GCwkIBwMCAxUC
AwMWAgECHgECF4AACgkQMo2oZ0UPiezRGwCeJ4J/wVG7Vs1Uf4zlkrHcGsA5O3kAnj+9Fz0W
ZJWpqCqY6r75Fe0NlDg3iQEcBBABAgAGBQJa9Kp2AAoJECBWhy2NZBIA0+AH/AtE1V9SKfmS
5PZlkb2MbyPLGAPr3CA/xXGqchb033rx/axmVymXzHVSjvEv6wloiKGf/QczWuFeZDz1kSRW
ymCPSIat+bUQKFR6z+Lgw4ml8GdWyShdV7tuqvgaG9+bjpyYv5z/8cqOldjJvQbrEJHP5p8X
khIjCQA6v+0pQp0lSsVvGjA5AjhNSGetSHsHx2AMke8InAhpOrYOit7b/o7VNj1D9irQhcqh
pA+ozYia1ldcUm4nkBfUBBT9M97IDsARlQqeDVeBWKwPKYpCNIQhG5Qlj3N5kz7k924JUZN6
tgTfb1Osr61jSorgQ9gDYpBawl4/b2iQxgrKJb3aV16JARwEEgEIAAYFAllbmLEACgkQI0Ub
EHqgOUFFGwf+KCZeXQDxPgTf7KFDwVGJutYgCnA0geHesEq7kS5HLH+oCZbAVwyZify7TaT4
Bi5a3gK86LvbHVfOlZVc/JhJwxOQ8h9TZCGW1fY6XVw50Ghi06ki792fnKYvTQpSU54dxtdf
ziL+8IW9zGb7h0uuY4A4M/Qx3+MSCt7JDp9XBx8eHDl8KF9bU1qU/ZzNVC8Rq4WeLs6p0SQJ
O9ovd6DnJ+cSweG58GpzQxLV5D5gHrb5SoG8CcwvRYnSCLzfsPkUNy45HjQrE1S+YJ7o+F+5
v+qCUAZPrQ5OJrpxYnnLPU7K3IX7vFzDS6vrQ1cwEzODLveGfTZBHdhMw936S9/7CLQzUEFV
U0UgQmF0Y2ggU2lnbmluZyBLZXkgMjAwNyA8cGF1c2VAcGF1c2UucGVybC5vcmc+iEYEEBEC
AAYFAkdcDv0ACgkQFfjlw8DQnmpD8ACfb+jzfDHCBsgop3apGAlYXl822I8AnR61QtmU9FS5
S4XtH0kNPg0k2IQciEYEEBECAAYFAkl8FPcACgkQ7IA58KMXwV2Z1wCfVHluJokYDuw093IH
4PANpcxKJVYAoPZgbhE1jHiP3zPOO4qmSIEuhq+GiEYEEBECAAYFAkob/E0ACgkQK44xRkGJ
7ScqVQCfXfr7DUxck9Lp/+qw7YF1nN0JGwYAn3DBWBvCe4/TzoKyoi1aJvk5CKa8iEYEEBEC
AAYFAkuMSNYACgkQNK6uszzRsMyUvwCdHc8dIoujSEyvQ8ljxGCs2S3WVjQAn3pzmj3yNyUu
vgtbwDbWP1jjLZbFiEYEERECAAYFAknLgNoACgkQNswVpONZZfyruQCeNtCwmAobK9H50HfH
HHaO3tqdva8An2NoWd5H3EKaU+vRe6UsBXeMva5FiEYEEhECAAYFAkbfAKQACgkQOV9mt2Vy
AVG4zQCgqjZuEOhiMNY5KTV4jb4Tcs8U68EAnRnYXc6ZsqAuLfdH1fGYz9xN7zpGiEYEExEC
AAYFAkqYbe0ACgkQ6dZ+Kt5BchY3hQCfc9tc06DUM4+uVGSkP8UFIjq45PAAoLbZGEEFDJuy
yE429ub0NaucYCgaiEkEEBECAAkFAkfvvA4CBwAACgkQX9tx4S9YpStxeQCeM+5SjYw9vT2o
fmFlMsCo+L9c+50AnA+laELg+fJJWRMoV2796vdV0Rv+iF0EEBECAB0WIQRZHhhUcL58V8z0
UW2abZJij/3JQgUCWKbPhwAKCRCabZJij/3JQqLvAJ0fyiXiZ8uJyLBl/ic3ktLM1oAL3ACf
XzOvWRWW39SuisUJDT8qGOpYRECIZgQTEQIAJgIbAwYLCQgHAwIEFQIIAwQWAgMBAh4BAheA
BQJJeN+QBQkPznSAAAoJEDKNqGdFD4nsKc8An2CdOIi7nfZryHF8GJJd+J9NtLFpAJ9eusCD
xCdGumv/+ftqd/gKJ97YPYhmBBMRAgAmAhsDBgsJCAcDAgQVAggDBBYCAwECHgECF4AFAk1z
88QFCROSKWgACgkQMo2oZ0UPiewvLACgiE8QH4ieOj1oiU/jKwxdel2/8xoAnR6+jzuAia3T
zwBDwFzRXKDn1yB2iGYEExECACYCGwMGCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAUCUYU0FAUJ
F1RQBAAKCRAyjahnRQ+J7J6cAKCIsRIpXhlfAFzOAq/OaU8wOza7ugCeNu/TS6kC3Lic1R9b
GE6hRzIAa9KIZgQTEQIAJgIbAwYLCQgHAwIEFQIIAwQWAgMBAh4BAheABQJU13atBQkbF/Od
AAoJEDKNqGdFD4nsXiUAn2tEAi+CaG6aL4mmeIexV06WF6+OAKCAdlkRl/waL73W77pB224S
Bxd1v4hmBBMRAgAmAhsDBgsJCAcDAgQVAggDBBYCAwECHgECF4AFAlk988AFCR7ZpTAACgkQ
Mo2oZ0UPiewlCwCgisSO3WSqE7Uk7en6trRSAP6kgzwAn2Fp0hojG6bN89q/qOWiI8v8UTEq
iGYEExECACYFAkWZgpQCGwMFCQwMGEsGCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAAKCRAyjahn
RQ+J7Eq6AKCEdJZ48JV3VAb/scyPM88LmGa8rwCeKHfZEDwGBXGP7evABJMxqqRhOwaJARwE
EAECAAYFAlr0qnYACgkQIFaHLY1kEgCvqQgAg3rwZRUI6zbhYAV2Go5427vJ6+UOZYnHakxG
wam0qKGjc74j40CI6YNtzD5UyFozFLhQADri6PHdWRhCtbCP/bScnkxCWHIkaXof/of9TyKj
6grKtOM88SjkwKeUbCbJL65bETWbwQmKlKMXSUkuZjwCNQEbi2v9gjIrUaPdxBwk0b1rcDDB
YdFP61c3yNRQeYFQ6gknuDAFBWC++Wesq7FOwlbvYOMeV2bMDBm69+O7giEEyK9MmdvDRzr6
CkYsCsUQlQQxgdn1DWO1wo2Dhb3crtYGLT5gbdQAWbURd1+BYrylyeTueNVENUvyPqO2CPlO
txxaM+14wGWpXvgN5okBHAQSAQgABgUCWVuYsQAKCRAjRRsQeqA5QQ6vB/9lYFve9t0PiABb
V0x/523vRMfSB8P6wipP57PAfcMNIwxODLwaKL8p7BRpwm572DsZo67Efl64EMT/KRZa18LP
aJtVgb87zPQ+J8Zvl3xqxjyY8N9X9+lLmDtvMg8mBc3yB8214h08PijsFInpOUSQVElocIwr
mnpmDfmqZxkFePv02vKGDsZ9rDZ7lJZO/+0vevIr1sWUUw4ZDtPPxpxU9q8SOPyuO3xqZsyr
hCaLvrRzuP+zSNUIY3J40QPeBmQRLLPyuE9EHnWe/BHFf6anvWRvQ+aqx68HMZWJGm7SB3DC
suavJPNRd3NkLjeYGDqK9vyhSvgy/lq9QbkKu6CItDNQQVVTRSBCYXRjaCBTaWduaW5nIEtl
eSAyMDA5IDxwYXVzZUBwYXVzZS5wZXJsLm9yZz6IRgQQEQIABgUCSXwU9wAKCRDsgDnwoxfB
XQBsAJsEku5xBZsf7EYYkWeSEiXnp2kLtQCg0V2hlzJnDCFFqf/WsMqL2glkDjOIRgQQEQIA
BgUCS4xI1gAKCRA0rq6zPNGwzHiqAJ0dtAvhlqh/mH7rk1zV5d6MKUKBZQCg5lO06lB5gPX+
RrxJrJ/2ThyQauGIRgQREQIABgUCScuA1AAKCRA2zBWk41ll/N3WAJ9aV3ZzqMCiXbFrQwKL
Atyrh6wI3wCfYKAvs67QENDfq4bvTHk0N61MA1eIRgQTEQIABgUCSpht5gAKCRDp1n4q3kFy
FnQ7AKCaTGJjbuTiGwPjxRSYLdWahh9q3gCfTYZNWq1+9I4I01veU166Nh7G1KGIXQQQEQIA
HRYhBFkeGFRwvnxXzPRRbZptkmKP/clCBQJYps+HAAoJEJptkmKP/clCjagAoI9tiaMY5KTI
f/7669XX/lNm4z0iAJ4sFiaQrtc3wF8O5N8U1wCwqa2pPohmBBMRAgAmAhsDBgsJCAcDAgQV
AggDBBYCAwECHgECF4AFAk1z88QFCROSKWgACgkQMo2oZ0UPieyf0ACgnheEOTIZ4z7/1ZMG
5C0WjbIqPf4AnRkkzf8VTHeVpEQwuC5ko2/evIx/iGYEExECACYCGwMGCwkIBwMCBBUCCAME
FgIDAQIeAQIXgAUCUYU0FAUJF1RQBAAKCRAyjahnRQ+J7OusAJ483A71/pnEw5+lfcer+DLA
GqDFawCeI+6X/01UcFq/xLpwxr8aBJ8gmuKIZgQTEQIAJgIbAwYLCQgHAwIEFQIIAwQWAgMB
Ah4BAheABQJU13atBQkbF/OdAAoJEDKNqGdFD4ns+q8AnRd9dhHzlWUMh1tglnJ3vZiE5cKk
AJ437u6cAMe2WWE6+jQH78tsr96MWYhmBBMRAgAmAhsDBgsJCAcDAgQVAggDBBYCAwECHgEC
F4AFAlk988AFCR7ZpTAACgkQMo2oZ0UPieyy4QCfU9MiAvJrwTIq1tBZso11JEx6OvkAoIWU
trpE2mftIOnS6rXQIyqZT11UiGYEExECACYFAkl43/ECGwMFCQ/OdIAGCwkIBwMCBBUCCAME
FgIDAQIeAQIXgAAKCRAyjahnRQ+J7IDEAJ40F0fyg6NTAZ2nWizs/C/RSPYPsgCfSqnVpaqF
6k0H/5AabfdNbcS2Wm6JARwEEAECAAYFAlr0qnYACgkQIFaHLY1kEgACigf/UHcjWbCrfeS0
fgHDhpa+wLipjY621gAMROefmE054qlDMx912rG41CvtG8ss4hc5TG/BTPoHRPtnKTlsTacA
G5dBGjGaJXWG/62Bim4c3gRm8LSuWcDL20f3U4ySzxyyooQDsmfGXa6nUvQA4wYynX7qMJbN
VfM1Y22oVR2GPiAkql3psXegPOk+nQGOmDjM6G2/mF4r5C0SgHB6NoDEuAIFU+agC7q9UTSB
BjW3GiV9iJSALvPgJEmLM7VvcqOF178DJo4Zwizo7/Tkxn8Rdc0jRmObW89lm22LDVMUl+qo
TNOIByWQa31rhrZidPv3xpeogU8tjYf9mi8ZcveAc4kBHAQSAQgABgUCWVuYsQAKCRAjRRsQ
eqA5QcgYB/sFo99whZ48nhPL1BylIDm7Dux3lR2mWaZuVR1rlTFdJUXPjRLMyAScnzS+EkCZ
FPxY7hJPxM2frmEh+5x4UiKrzWjFsZxAxXYX43zaDDj0zzFQxXqKxEfCd9rZHd8PTjpUXok1
G7ohaNTTOLIzX9kMpcr12dFd2gkP9KeG8UjJ9/30HDLE80k8TWrJchyD2ISo2fVoCMAjo0lC
u0T6kKPwE3nsgFhN2gQGp8UWsFqHNPI8GYkON5HAPnAPb/olKghIKOpgrorYVK8aUVi8qZGR
nainEXBmEVCRuVjKY9cbfsSbzkxz5dY8SkfXHlRAmgk4p5mA0DDojy5FFYswsJAStDNQQVVT
RSBCYXRjaCBTaWduaW5nIEtleSAyMDExIDxwYXVzZUBwYXVzZS5wZXJsLm9yZz6IXQQQEQIA
HRYhBFkeGFRwvnxXzPRRbZptkmKP/clCBQJYps+HAAoJEJptkmKP/clCUzgAnAkAGITUb2J0
LpbBENwQgwaC7M12AJ9DCCAiBiu6uOn0zHgD7OJ2xNN4+YhmBBMRAgAmAhsDBgsJCAcDAgQV
AggDBBYCAwECHgECF4AFAlGFNBQFCRdUUAQACgkQMo2oZ0UPiewfdACgm/4ZWtkDfnjFRzTe
RJ2ylDrCqVwAn1dMVTmBacXAttvYY0+8rSffBhw1iGYEExECACYCGwMGCwkIBwMCBBUCCAME
FgIDAQIeAQIXgAUCVNd2rQUJGxfznQAKCRAyjahnRQ+J7N/lAKCA2jLsifmnRjNy7YLHRL+V
rFT4kQCfazBfsjxs3b0xW3rrSm/mpXWi03OIZgQTEQIAJgIbAwYLCQgHAwIEFQIIAwQWAgMB
Ah4BAheABQJZPfPABQke2aUwAAoJEDKNqGdFD4nsLK8AnirzM4j90VxFhUJFl/EPgUwuPCfP
AJ9TmbY/wkogUTUJrfSSHb1nIL3SeYhmBBMRAgAmBQJNc/QHAhsDBQkTkiloBgsJCAcDAgQV
AggDBBYCAwECHgECF4AACgkQMo2oZ0UPiexPEwCeL69bpAn0wGnIuU13Q4cz3ZaNiM4AnRjL
mDA7i9+Kgtq7Xn20WR10NYZ5iQEcBBABAgAGBQJa9Kp2AAoJECBWhy2NZBIAznAH/1g8Nx4k
08QfmJ3dr6N50rFXF0VUDq/aXAe7tCFYjBflN55cuc2RZFoe16sfWBo4/7dI2LxCSuADRvnB
EEdE7+5YQsQbsKfonilABYx4mfj5R0FLE18rfL3+LL1Oe//vQrmkS5Hl+wt3Cz1Ot/F+ctwx
LmafLd8tz+SWFYskvcg0SlxdkqvPBHesqsr2Npr6x+xqSKRkWM/ovPQUynlDcOYe41DoCadD
6ztwzTfEHkjwhug9Mzk5l4qMrPsaXEjo6vyMLeB7Eb6Hka3R70J3t+rEDWMaoOjeDDWsGKb0
jK2N7hA+QpHvd+KS8ZhoEWrhIsaeLvUTsIFapgSS9q7VyK2JARwEEgEIAAYFAllbmLEACgkQ
I0UbEHqgOUHj2ggAg97y2tJJTWS6RMrbAPZLj3Gt8EAIOnjb0adSZfN97f2d0yE4KIT7NgoJ
ngJfFUJnKx/uiZUaJqSdgxxEYk99hEgthJfIOawv2UbnANf+89NWa49EV54nzfTpd0n4Cgz1
EjERBsRA6tK66j5Pfem0sIHnR6WCk76UHiot7HvN16D+oaFgVv5orASBuEmv0YmFuGBm1wWN
UJ5Tg8RkwzWvzS/C2qPeT1oA3MfSlBDBbYuD6E/xGccmcTaWwHgos+aRrfHSoCL4y3HZg5Iq
l+PU061a+N8CXYybmIPxttvrNyoNnl28QqF/AdVi94dyNHkB6a44y/BJ+CSdlenIGmlUjLQz
UEFVU0UgQmF0Y2ggU2lnbmluZyBLZXkgMjAxNSA8cGF1c2VAcGF1c2UucGVybC5vcmc+iF0E
EBECAB0WIQRZHhhUcL58V8z0UW2abZJij/3JQgUCWKbPhwAKCRCabZJij/3JQh9aAJ9Y4kSv
ZH9MjaVx466Owh3LM7eH1ACfRdOImJHgBlYKyVZJSV/yW2FfoVyIaAQTEQIAKAIbAwYLCQgH
AwIGFQgCCQoLBBYCAwECHgECF4AFAlTXdq0FCRsX850ACgkQMo2oZ0UPiexVnACgiUll56go
Pt3HZQC89EKFeShExPAAn2iONohuStqxgANqh0UyzD2uCsMeiGgEExECACgCGwMGCwkIBwMC
BhUIAgkKCwQWAgMBAh4BAheABQJZPfPABQke2aUwAAoJEDKNqGdFD4nsAFAAmweVXa/l5fYS
iI2GardDsglH2cQrAJ9j8uU8OvkC/wfHYHBhleL+phCfwIhoBBMRAgAoBQJRhTShAhsDBQkX
VFAEBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAAKCRAyjahnRQ+J7K5KAJwKnTyxNZIPtBcG
qU4UHgferdR2cwCgnwMSkY3d5EsPByObEjvlMBfu7VmJARwEEAECAAYFAlr0qnYACgkQIFaH
LY1kEgDiwwf/aaSyPaCcQYtgI7uXXPvMuwzRoFcttSBwlziUwrZahxnK0W9UefVQZOxKo/YR
UZ70lbaf+RjVuCTHqb5GDigMAGO6eyi8oYwQjqut752EdBbrR9vklwx3Pj8F41CPsfEy4twD
JQ5uLdyz/Ha2A7WNA3yDCgBOE1mcUTRyaGPT6Z/y5CRz9n5WSOG2gEFL1hbFqDjMXUGIIMKx
YyaVffTw+eV3jg3QYcqSauMHhNMrxIvC2SuqcmV6zPlFYS3xs79Sd8Ar9DTF+AW+bV3BBOrF
XIeuPZWkaI/N6TDLQ7aaFvvj89NBbClPxpX+S5+lChP+gTCErrufxNWFPH+qA/1ReokBHAQS
AQgABgUCWVuYsQAKCRAjRRsQeqA5QQo1B/9yKpLsBSvVa8ntVtF49AxC1Z06EVag5DVF1vT8
a4hKtrsPmmDxJz5kB6lffZPTMAvStzrpB4lducBFdFLKGgmHYJXchDevZ4wm0JWvH9xRUOJZ
e/HgEZs072kv3OE3T8lc7rveowwyYxE1ufQ2HC7g6hBJZYb7B28UtW7yZdWAY+dwgJ6KpLAf
g+fM5VGLx2b2R1Gp7PyhWiO0pI5VMRlRRlvLjl1mopodULTCjipxdTE6jAZx8rDw2ULiuFMT
UsiRt1/gxmKc6V9zbxFlJQ6pPJ9b5BIA1slOd5uQiIrtcnEaSkWqiTbIm/QcMz9DZ/vyo845
4HIyArDF2twvho+LtDNQQVVTRSBCYXRjaCBTaWduaW5nIEtleSAyMDE3IDxwYXVzZUBwYXVz
ZS5wZXJsLm9yZz6IWwQQEQIAGwUCQ8HT8QMFAngQhjxbXj5dK1tALl1cKj4kAAAKCRCG5rJN
klhP4dLcAJ91HEN14NgMjphgTJ1DnYKTR9vAkQCfa0kAV5xeQ6krdar/Q2m9mrKinzuIWwQQ
EQIAGwUCQ8HT9wMFAngQhjxbXj5dK1tALl1cKj4kAAAKCRCG5rJNklhP4cnmAKDWuK6AlsGC
3Dh8tv9fR2xni+slaQCfdQeoZxSCEGbE+z7kGkdtGIcm+KOIXQQQEQIAHRYhBFkeGFRwvnxX
zPRRbZptkmKP/clCBQJYps+EAAoJEJptkmKP/clCj48AnjlF6e0q90/QxxlZ1MhvppQxUskH
AJ0TDq6GpMN1tMBWWISM5Urq2xB4rYhoBBMRAgAoAhsDBgsJCAcDAgYVCAIJCgsEFgIDAQIe
AQIXgAUCWT3zwAUJHtmlMAAKCRAyjahnRQ+J7Iy7AJ9XmI0nsRV54ER1VgxE/3jFB6WNQwCf
VIYgdjfoKww32+oRlKrExslki1eIaAQTEQIAKAUCVNd26gIbAwUJGxfznQYLCQgHAwIGFQgC
CQoLBBYCAwECHgECF4AACgkQMo2oZ0UPiew/rACcDNXPuCrG2UsJx2JkyCtysQoDztoAnR4C
0Xvx46bfJwcgzaZRyaVf6ge7iQEcBBABAgAGBQJa9Kp2AAoJECBWhy2NZBIA3lgIAIi1hLs6
Obhd+JZcFRem5IleGprUgwipZmgb2W6WpK3vs/xiwCcn9XUbbdpPXAXMq0QgLrYjriSYB6B8
41PcTVoTOcrd8ZhFMdmToZMj16H2ZnkRux2fvHe8u2Tf426aMeFkNfDu5PAFC637KCyAmZXs
f+cI9O2d6o2EjE+C3bhE5Rwl2q/spZIlp3IQkrSvGMlHh1CMWNoZJZ862Em4O0k/WbSeCFk8
84wSrH2ystMKIkK+dSkKmAwLN/zOopGfvypLb7fvnJ2Okaox0dWnyji3jL+mJYEgIAxr1uxK
tfxhLfIKTmdZQvGQ46JwrRvCws885XigXgLVXQoOn11QTZ+JARwEEgEIAAYFAllbmLEACgkQ
I0UbEHqgOUGrJAgAs/7Et5OYVTkpF4YovJ0SHSDZZMDwZRnhxFZgWscPFq7D58jDMM8uueKF
eGuUrhEOBXfQ9gjZ0/0/cIrbxbJ2Moih4s50Vnp0Fd/16nMZaNjEyIcyHVW3dYAZDMS23vAk
NEYwdUYLCYsFCQaWyS0WS+m4iODG5EbEgngsEYVQjHQXrFfuEkUbCzefBFhGWWEwm2lJXSkN
vPU26t/VPzydG/ES43+G5E87YfVi2zNUfA78F+/cqDLFvWMqt3WYbd2Ek4xfoWVgSoI4zrB1
k4FQbba5rI3yzaU71abjqolGSWbdWdBaJSXF27nBenZnPExapWLU71rSWDJ4HdxR7FeSf4kC
IgQRAQoADAUCVwiffwWDB4YfgAAKCRBHG8hU/AIu3t6gD/0cH10tzMNPCY28MiUc3qSlCFo3
CupVVG3xsCTxjcxfW37MDUgruY5NhW1DouvVGxcSpt5h0UYSCQuNYvsXwkfUO0hAhuG8L5Bx
iryjaRSw+gSwD47YrhGieCNJJDcUbhw9YF2stB1yIc/9EYMm1599T0p9ve0X8cuxi5DrE0mK
NMimT+zclyfpGAE7QtmG2Y0FkpjjVm9WgVTwPUNkW5WY3SAafnfesxWZAY79Z2od1RuuD9eQ
uokWi/0h/SqInj5FpxFUl4clV2uA0sKmFqHaHkuoyOeiTL2mVxqXHTKBnHH7ygZQST9rIdEf
CUFcIjMyxC1nm8Q2V3FWWWdjUMN1OoB5FEPp5ozWpd61TSd5m0XzUaCPCtvcQW+K0+z4PPzn
31QvCgtkINDH+Iq2FLSGazyN/9EM4aTYeFXxnG9/eIlh3C9YBD6MBPR0y7ueu4bOtOK+Tk/I
hq7IaSXqA6CXlc0gcY+W2f1GYMQk/PJrdIRMI7j8T1ymYQMB456Nv9bAdvEe03n/Eh0lG4zz
EEQVgiCfO2S2xk8NYkojMTLoGfjUxbCmQBwDMNaaYs/tEqhRqYnzg384WWxgtKOnpsV4TTX9
SxLs2HmY+W+gLlXuhvN30PGbzwlZkDKS2sHExAB3b150M1H3MOBGLbneBPjabpcr/mYxsdJY
dKnk0ZOOtLQzUEFVU0UgQmF0Y2ggU2lnbmluZyBLZXkgMjAxOSA8cGF1c2VAcGF1c2UucGVy
bC5vcmc+iFsEEBECABsFAkPB0/EDBQJ4EIY8W14+XStbQC5dXCo+JAAACgkQhuayTZJYT+HS
3ACfdRxDdeDYDI6YYEydQ52Ck0fbwJEAn2tJAFecXkOpK3Wq/0NpvZqyop87iFsEEBECABsF
AkPB0/cDBQJ4EIY8W14+XStbQC5dXCo+JAAACgkQhuayTZJYT+HJ5gCg1riugJbBgtw4fLb/
X0dsZ4vrJWkAn3UHqGcUghBmxPs+5BpHbRiHJvijiGgEExECACgFAlk99AgCGwMFCR7ZpTAG
CwkIBwMCBhUIAgkKCwQWAgMBAh4BAheAAAoJEDKNqGdFD4nsV7MAnjckLseMQ3sX6qneJIcW
JBjDSrsVAJ9+U75KS72ziZm6a5yZvXG5XItDCokBHAQQAQIABgUCWvSqdgAKCRAgVoctjWQS
AOc/B/9U1SYJxS9VNQG1y+7Ds6+nxmNxr8uWLb55lW9oTIRkVwpWi2EcKNi9/1AIyFR73nlj
fm6ihUo/z9V4B6dH6dEG8KzAQLQLOjNg76OxBSz2/kCBEq9jBnpInmGF6lfwYFCOGPYUDrCP
+uQ2quTlkZRgLYovy1HYqVSxAEvTj+LBgeVvyPk1erTp9FKYoCnHZYvdOSlwOcthm0SPCeQC
NIDAXJJw46yhOKEUohlyuE01j/mbc03/LX/NhS9czNZeJm56cLidOlzlMLEf+kSH9ewYl38S
OcXEgGCQviE+Rso3yIZZT0HpPzjj2DGy1aQtEjStFr5/Qfod90dENhMKstWwiQEcBBIBCAAG
BQJZW5ixAAoJECNFGxB6oDlBlwUIANO3BcgfAf6l3jPJjBkIYsM+te4SBQLHjYS2kpDl2eQw
TnjLlyClX+7ZTQHRUCGHq6fnK5wVG19uJjJPDLqgGRtEiym/oCYbglvM74mQUaIm2vbrtlRa
nflwKn/2PtUULSm4lD2/WuUYI83SUMuRMcFrKyyWhUZZVL1i+TTW2hWyQvO2rWYpuCHjY+A5
1WbxcKAUiq0QfSApEwGYT5e4vsLeWKKDFnYxIGvQmqg6pyXfOa6euvC8zmGZnQwSlonmuti3
QXJPv9RloiX+327M5XVDKA/ShcE1cM8y0uIAEb94whzfQg/gpGwOwwMTYCM2reQ46tFWH4U4
59kHsOssJqO5Ag0EPj5wshAIAIwCg3L6aILyb0q4N65LLQ4cT+DviWb38c63S/UJNBTwZW99
RAsTzAX9syjm68BisMYA9/pUm/8vUoDmJwLLsM7Z+gao0PAFSoiNDBQ02vrS67WOfOtF+08S
Q/W8zMfwOIBLGKBWWEeLP2pRgM3KhXHUNiIhZyhOCj7TVxDEOu5QhMOc3WEqCbWvSVCrAl9y
iPwzp3tTZ4zWS9nUGnao7BHPJo71Dk10htbAmsM0z+bTaDx4NdxnsidFxh2x2N+QWxd98q/Z
D++vs0BWojMiw1J8kAFP9D/q5vyOk7OquDmcCiv7QuSw9Ejw3tPLgM5G+JK0asYXqOrHh3U+
x43Q2ysAAwYH/0RqUIYWXPhfaO/UvWi1eF52OQhXr+BCb1KqukxfVdK72YNePJmzv2/BLTn3
AUnbwH6Nx/MOsHAu1/Crf+j5evVGSrkDrd+eNPdoE64ycoNbmQSvRMvy0odJPgTQnyMNOPul
vIowEZKXaAa1NwsAyk8q6FmJEhQ5JMy7yUU5DKVaasiNMSBBMT12U3+uwG79Xc3Hkw3Im5Sy
X0HLHw8lmL/A9dhCxMy2EJxTNbOsg+kOdV5P10OjCefWwd7rhTvFaZAjBL6iMWV7C44KskIK
O98tahYs7CpxRvk076KAXRt8qkrfTrC0qEayZGWzF9zyqW09HHli/HVC3Nb9qJeHyRqITAQY
EQIADAUCPj5wsgUJA8JnAAAKCRAyjahnRQ+J7EuOAJ9eLBV+RNoyXPOxxSXqj5nmrIXWsgCg
gpjqo6NAlubnqTdfaV3T+wbo1DuIVAQYEQIADAUCPj5wsgUJA8JnAAASCRAyjahnRQ+J7Adl
R1BHAAEBS44An14sFX5E2jJc87HFJeqPmeashdayAKCCmOqjo0CW5uepN19pXdP7BujUO7kC
DQRB4aCjEAgA0TpR+0K5pXueL9+JfMKqX4yxTqCKWHcEP+cvHSgXOrBB8Y0j/NKMMPj2TIf4
I+ecrlIpkuSGjXrurT0GY1pMzQsWZr6/gRIkzynpCaQlcuY9m9Qk2QuepiI3a6g8Y9kojk5V
j/CTuxmtKreQIzpYiwuocvSv9tKND/MG9MsYJdGsy28MWhz4Ig8jhiPRC9KdppOCmZo+KLRX
GHxsrxItQ9n0NtLvTPkvWf/3MS/pYCRSUwHuXUGqvn1QT6O2RlbcYXopAlZEyrMmG6UwLltq
yNdpUmig0/ECOrSHUBWKdluPUIzxWr/UHY6yTlG/UAtenLJ4Tos9de9mmfE5pCG/bwADBQgA
nSoRZaLMupdhs11JlnSqnWOhv+cGjCspWjWNX5RytQ/82CRC2IDozzJkY41LGqPHQkEO44P9
EoAYVLHNXgzq/17sYlcAydJOWv/dsjcaKd+QAy3JmYkZdCeyznF76tLAM/7NMeAvdA2a3qLE
+kkBYITpvcA+nZZj6KKWiNk1CX+sYVPTPt+LgXwGuHffIMr1CoSxhxp7GqScM2eNEy8Lex05
wHC5Sr/3ucdHQ1wxxH/hpYZz6Q1bIM/bFOYoTtFg2crvjRtMS4euP2D+fBCIp0zbzyNlcw+U
8icsGpp0JV7kG11XQntg0UiApA18Qvwon8G7SlvGMC80A+GzUKdqEIhMBBgRAgAMBQI+PnCy
BQkDwmcAAAoJEDKNqGdFD4nsS44An14sFX5E2jJc87HFJeqPmeashdayAKCCmOqjo0CW5uep
N19pXdP7BujUO4hPBBgRAgAPBQJB4aCjAhsMBQkEBFIAAAoJEDKNqGdFD4ns4T4An1oxYBa0
a7a7oQ9voKKA6H6KR+FrAJ9C3GLAh2cX0rJHieb72p33iV7/TLkCDQRFmYK5EAgA7pV2du4v
VF/P6R6UPEWHgFh0LgiNhxoyP+nWSC/6F2etZBaaaS4DvoaVBGfiQ3SjCP5aUrsdeBckhN4F
+sO42ZX1+ioAXQYrZ3i80NS9LbwEzeFhgCA+u5MnF+HzapwSI7dQEJchlgbOeAIA5EfS3lbg
G4jxUbfMBgvTWeKi/c6S9IFo9KPaRm9GyScOcGqdZAFRJN3NUKMOPiVdiUxJdl/K1434Vcs9
DSMPY3nOb56PJhjSWK+k1IjcV/zOTxSXNJVKnzS9+eybSpgBIkwJYfKxPZQndmEdR4btgwZd
D6FJ21h2YlPJBc8BpFSoIal2Ulz/3d1KbCoE1GmduMDGDwADBwgAu1P2QBZ7uDREdcowhYX6
OR/JeMkdV92ueoCTLUnVZv//tNOL5sVVtGB9l4ZbsFaJ41YlUs4CIQu2nGemAKm6fAztVpZo
JZ0gNbqIZ2BJmK1ALvR4clBqax1QudZDEcvz5C+ej9cMIzmnnk1PDSE/iH/jBXxVi+QQncd0
mpFqYZvCeAUsH/GZwAEwqFDbM3kN+Z+ED9Fy3xOYpBmfUpMCH+i+P49dNeCvNFyRtPElQ/Bs
RbVdUJy8xZUMT2NZpfR/cLrlWMN6TNPRgAYHeLIlPLYsYsje95/ZSzEXeDP52HAjCVlXTMdh
bvQams3Ozvmj+/+pqcB7q6OmzZpbLMcCBohPBBgRAgAPBQJFmYK5AhsMBQkEsQaAAAoJEDKN
qGdFD4ns+ZMAoIthsa+zF8MlnHDtmFpDKTJoH4FDAJ9NeBWYgAgj15TYGkXTsXm08udw4bkC
DQRJeOBHEAgA00U9g46xUZsyTsPjbRZAcLRJuz4NVE/pTbnicB01A1DD09vIUHS/CR9Z12wU
QD+D04tWVBW5KwhWACIM24ojFFPcYClnC0VjPkzgd9z3bcc/34KjnSQ3BgpuCgHjdGRkH7X+
kWydwfve9eDsb0Er8Sxne4xX8tWHG7r7FHyufHJ+HgX/XVdW+udnp79vU2fpiRkO0S8ymQXm
MDJ8nILL9Q9PyzmRAVIoXn5sHubtOGW9x35nq5xDtckd6oTJZjddEGxSTbVm7wjOQviEIt2S
FedGNsc+kitlDsAuUheMBRfiyLNKIcr0yqIvaWQCd76NCCx7wtq263SMjwyxQ7A1MwADBQf+
POFyawQBxikgLBnfPm/LKetNgCRJ9gHKspVcs8WkKFmsBUJ+Aq7Sg+qx3MRaPjt41HZpm/8N
fzDb89u+oBmCo/wZJDLjX8rWD0oiI9S5SWrC6ObQ5Vn4MQCEGHQncckuKdH4dK7FCqNvsKRI
/PsSbwY/Ux+dA9OeAfEdC5Df1Ju7TpUzwih+bOCy9HrU4xLRz7JzjfFF+VOtZJqK7qGcZ2si
zRYofQ5lBp+R4fDODzC3D6fBiPijcX1MUNZ5UH8ZIPXJQIntNN8CPBHumBOhDjkEuF/tEwRb
ZTVafxUUFaN/3Ajfj5o6u8tbGUSEDKiwcE5/XTE1BVbJ5hyMnb32TohPBBgRAgAPBQJJeOBH
AhsMBQkElAWAAAoJEDKNqGdFD4nsXKgAnimNgelmdpoudNOPKAJNk7gI6WOlAJ0eSoRxUd7a
7v4Tep93L2I2x0CrDLkCDQRNc/QmEAgA3qSWyBuybYF85PW7vNSM63QoKQbr6LvVNBggBzdX
3L4ioeTi9jmqb6jlIRx+rpq2MG57POMhbtiQqfHl4dNkR4d93Optk4dyIgy1n+Hk6zKUbi2U
N00pMOVFdJq0TWa0oX4qZ2idPsdBstUfw1m32ozU4ne9JZagyF34MoCs6TpQjiT+jT1rh87e
BTACYrxR2MssG8OLGuQEcrQ3LXlHxkQmmGmvZMqwoJZ44VrPWmuTjuyYR/qhBUpT8geJvsBd
gLR0qTMpmLG75c7HtfmfYoWEyd9q5N82dYQJvYhBLO4dM4SZ+gfIp0BvGAOIyoX2sTvH75Mx
j7XNW4jnlvJd1wADBQgAq7+p4/akEHDIv79bbRtx2CvB7KoelB9s91pxfh8AkXGt2YAFqLGi
zoolpGOPvJbqCVDsgOx2VtC2IPYJT+0OanhK66ko7sSZ3faMQ8a0dFWB8CiMgrtXAFtKT7j1
evVyJ4BSAKS8aFRFqNDVRrucF8fBhFc0tRURHroD3rM8kG8/sOntFaqkAJ/ozJcqcpjSRw5+
XltfUjM6YcM7iCgEz0kq2qsD4wp/80h58yRTy0uXGQ8DOt3xiuh85DRC8UNCceXo/tawYm4s
QfZbkqh7YcnHb/E4IFYnHWLC13DtYJxSF2+qlENH1j2p+ngm2IJYJQiE7JaikIwxruQtfE9l
HYhPBBgRAgAPBQJNc/QmAhsMBQkEXKaAAAoJEDKNqGdFD4nsf74An2Gya/xsz527QJEKxDx5
M6OE8oaOAJwIPBled8aFVkKMwA7ikwlxhotFVLkCDQRRhTTBEAgAl//enCPC/1M0DET80M2Q
6zQw54wRwTI8PiqK7OL66v+B8vg4s0UIWX4Kswolw5vbzlQliWoLfcgsZDnEwlTMgKulZGxm
OM0C6eERw9dHL/K+BV6bUVu5TbDq5JOpnjMA2Dh2/spjKHge9RlqcdKKwf6TsTrzCKnBFAyz
zinO1cVBzWsPBfYe+hqUQ+eSQA2Vsu3BNqSsWPjZL2v4xPm8mGjRrIMHuw8Edhnflil5Nu/J
DYHDJiWGLZep6sBYAUZwFg/iDGbe8I1RabhwhSeZVJZFDEcx3tlAxUw7jKqkQaO9TfUJE2/c
gScoWIyYP9sM3yvkRjVVRZAInYABrpTtKwADBggAgboche64dmxffWn29bZSoQA387pO1aMG
jgv2brNsRbNrvEEWWYuMuomPjk6OxLVT3aGYbhBlgQygYGBVw29b6GDMoTnX1h7KmZgQLgLr
OhJYsawMkI0sB0C+4lNjakomOMvdDg9ahHy8Ta+6QvEBW3sbgXwXABGagc1xTsyUpiz18eN6
wYOvTqyysZWmRNajbEOEW9zX/4eGWYTO44gb9iYYDWx4UsYyLUwLQ9/3pIQ4+L+3Cwrv1jAX
kIoPVdqR0UvggF35bm5KNwXsM2gGlMb02Zag2i4A3H3N5JSKgBAqzSHiCYJ1xOyyuW6twffm
tuhP6PMXCWpVHldNKFv5e4hPBBgRAgAPBQJRhTTBAhsMBQkEDYyAAAoJEDKNqGdFD4nsJBQA
n25fPc4h4xnB1fo/SytX/VPizNusAKCSbgXTDRobHH4A0KQxTioLgtQHdYhbBBARAgAbBQJD
wdPxAwUCeBCGPFtePl0rW0AuXVwqPiQAAAoJEIbmsk2SWE/h0twAn3UcQ3Xg2AyOmGBMnUOd
gpNH28CRAJ9rSQBXnF5DqSt1qv9Dab2asqKfO4hbBBARAgAbBQJDwdP3AwUCeBCGPFtePl0r
W0AuXVwqPiQAAAoJEIbmsk2SWE/hyeYAoNa4roCWwYLcOHy2/19HbGeL6yVpAJ91B6hnFIIQ
ZsT7PuQaR20Yhyb4o7kCDQRU13cDEAgAm+UNH8HJ1EtXNipMvtrxP+SaLEhi+idJrUpcNKY0
92DBpZfyMMPEAOG+7ck10J+7oksh3AQ6eQsj8sDs8WDefCANXz+YURNYUkm83VR8f1Bn9gRq
kezCsklOCSpIaaE/NFjvCIYtZKObTeCs5houHKWaSBulEnMcEzdIddp9DAGFKw8z9B9gIsIm
w4zbOM2l4FdgrXqIxCxgEuylZNxyRebMEw+HNOGDO4S1jOW9T/jvjqyj0RNUAuK/DnVWWYOq
E7ILbxZz5/TNKqtxQ4dqA9FIYXteWES51Ad74VfcoZ95s9tdeP6C7r+mZ8/tCZodkUhclAQH
tVvvB64ivgdW0wADBQf9HwO8WpgL8S4i4To5mv3TXevvSZoLRk58i4ecT/jL3brYFqM+Ieui
29fH8MJIineB53pr56Tdy+ECKdb68tD1HUJfCeM9CVsEyPUWVHZO4A4HkE9olzFnHvf4Lr9c
5ywxgPWtl+T8cFW4ldLs45qNoBuJiSDb+ncQyEE5KX/3oDkGb9IB9ypVBfAe5vdlpZCylB8/
dYDmUKICEqnaO1pZIJUODAquhz9zo24t3j2hfI9meb9q/ZKhgyRy4NnKziolx+dNNu8cvM3S
zWd4Z6MPXK05dvZQOrqwwoFVKMpRw0JZfn4HwD+hWJ5HAJGzk8CZp7YTGqkNNv3IKj+8blmV
n4hPBBgRAgAPBQJU13cDAhsMBQkEfu2AAAoJEDKNqGdFD4ns1JoAn393yHlqGQaIY+zvupmD
ycSzTkD3AKCK9qKCYRhg40aMgs++6mCYF/SWBohbBBARAgAbBQJDwdPxAwUCeBCGPFtePl0r
W0AuXVwqPiQAAAoJEIbmsk2SWE/h0twAn3UcQ3Xg2AyOmGBMnUOdgpNH28CRAJ9rSQBXnF5D
qSt1qv9Dab2asqKfO4hbBBARAgAbBQJDwdP3AwUCeBCGPFtePl0rW0AuXVwqPiQAAAoJEIbm
sk2SWE/hyeYAoNa4roCWwYLcOHy2/19HbGeL6yVpAJ91B6hnFIIQZsT7PuQaR20Yhyb4o7kC
DQRZPfQYEAgA78Hv+8VBFTg8YXoV9S3mgUYsWbBAFSCUECCzvEyQhQA7gcXkmtxmb86FibRX
nIuXp7bC48/pCO89wI2IzU1MMCK6RwEYj8VxzkhVlWLX0g4ZJON3hqIXIlcWOOXtTTmh8Ez/
Xqq3ZAtNXJpvwv3rbbWWFaL9aAQU+NAb+7eiCA0mLkZrKZckzltcBOk1o7O+GiPzIMPyfNBk
R1ZHbdeski7WNpqtuIr2/UCsJmOBTRBoEtB8tQL56deEqpxNshsiThFElKioftrioDkgV1KZ
FNl1ri945W7uS5XjAOTbUiCClLi2sqwgc5WdjXfcMqwsv7+PWk4v1Afw8ZxSPW0UzwADBQgA
sBfSPZAAEy8Hv071e+/7Xkyy6Rx9dhycjpqbYm/HDzZxfr6AJTPBkvf1wNetjWQVGfm5Wdm3
/3Ic+kY+HL5W1ENw4uPqGE/uJrwENPCMmotOQTxoTxDQop9vbVPZhoXbXF3qnMImXSafV3Yx
ErSNUPEIj1KEOyXXFxyhGlJqaarulG3HMMj7zSdtVFlb9Fa0c7XUElj1lHa//101d93SqX2c
eb/8BeoAbJ4SUoGYoE4OIGeUQqW3Jq0zGSuZkaqfuVa+dmvhCTO9dRHH3IKAYOwY5Vl2wQyk
mlyG1jiG0hDPWwjh6ZF/1r2vKihUBAos0zzl4ko6Mtq8tLKeFZY2XohPBBgRAgAPBQJZPfQY
AhsMBQkD2iIAAAoJEDKNqGdFD4nsjywAniiE8X+NCil6SUn7cym5Q2U0t5lNAJ9rMqrE9IRJ
xlD/KaaCMbuFcapU6IhbBBARAgAbBQJDwdPxAwUCeBCGPFtePl0rW0AuXVwqPiQAAAoJEIbm
sk2SWE/h0twAn3UcQ3Xg2AyOmGBMnUOdgpNH28CRAJ9rSQBXnF5DqSt1qv9Dab2asqKfO4hb
BBARAgAbBQJDwdP3AwUCeBCGPFtePl0rW0AuXVwqPiQAAAoJEIbmsk2SWE/hyeYAoNa4roCW
wYLcOHy2/19HbGeL6yVpAJ91B6hnFIIQZsT7PuQaR20Yhyb4ow==
=K6W0
PGP


    }

}

1;

__END__

=encoding utf8

=head1 NAME

App::perlbrew - Manage perl installations in your C<$HOME>

=head2 SYNOPSIS

    # Installation
    curl -L https://install.perlbrew.pl | bash

    # Initialize
    perlbrew init

    # See what is available
    perlbrew available

    # Install some Perls
    perlbrew install 5.18.2
    perlbrew install perl-5.8.1
    perlbrew install perl-5.19.9

    # See what were installed
    perlbrew list

    # Swith to an installation and set it as default
    perlbrew switch perl-5.18.2

    # Temporarily use another version only in current shell.
    perlbrew use perl-5.8.1
    perl -v

    # Or turn it off completely. Useful when you messed up too deep.
    # Or want to go back to the system Perl.
    perlbrew off

    # Use 'switch' command to turn it back on.
    perlbrew switch perl-5.12.2

    # Exec something with all perlbrew-ed perls
    perlbrew exec -- perl -E 'say $]'

=head2 DESCRIPTION

L<perlbrew> is a program to automate the building and installation of perl in an
easy way. It provides multiple isolated perl environments, and a mechanism
for you to switch between them.

Everything are installed unter C<~/perl5/perlbrew>. You then need to include a
bashrc/cshrc provided by perlbrew to tweak the PATH for you. You then can
benefit from not having to run C<sudo> commands to install
cpan modules because those are installed inside your C<HOME> too.

For the documentation of perlbrew usage see L<perlbrew> command
on L<MetaCPAN|https://metacpan.org/>, or by running C<perlbrew help>,
or by visiting L<perlbrew's official website|https://perlbrew.pl/>. The following documentation
features the API of C<App::perlbrew> module, and may not be remotely
close to what your want to read.

=head2 INSTALLATION

It is the simplest to use the perlbrew installer, just paste this statement to
your terminal:

    curl -L https://install.perlbrew.pl | bash

Or this one, if you have C<fetch> (default on FreeBSD):

    fetch -o- https://install.perlbrew.pl | sh

After that, C<perlbrew> installs itself to C<~/perl5/perlbrew/bin>, and you
should follow the instruction on screen to modify your shell rc file to put it
in your PATH.

The installed perlbrew command is a standalone executable that can be run with
system perl. The minimum system perl version requirement is 5.8.0, which should
be good enough for most of the OSes these days.

A fat-packed version of L<patchperl> is also installed to
C<~/perl5/perlbrew/bin>, which is required to build old perls.

The directory C<~/perl5/perlbrew> will contain all install perl executables,
libraries, documentations, lib, site_libs. In the documentation, that directory
is referred as C<perlbrew root>. If you need to set it to somewhere else because,
say, your C<HOME> has limited quota, you can do that by setting C<PERLBREW_ROOT>
environment variable before running the installer:

    export PERLBREW_ROOT=/opt/perl5
    curl -L https://install.perlbrew.pl | bash

As a result, different users on the same machine can all share the same perlbrew
root directory (although only original user that made the installation would
have the permission to perform perl installations.)

You may also install perlbrew from CPAN:

    cpan App::perlbrew

In this case, the perlbrew command is installed as C</usr/bin/perlbrew> or
C</usr/local/bin/perlbrew> or others, depending on the location of your system
perl installation.

Please make sure not to run this with one of the perls brewed with
perlbrew. It's the best to turn perlbrew off before you run that, if you're
upgrading.

    perlbrew off
    cpan App::perlbrew

You should always use system cpan (like /usr/bin/cpan) to install
C<App::perlbrew> because it will be installed under a system PATH like
C</usr/bin>, which is not affected by perlbrew C<switch> or C<use> command.

The C<self-upgrade> command will not upgrade the perlbrew installed by cpan
command, but it is also easy to upgrade perlbrew by running C<cpan App::perlbrew>
again.

=head2 METHODS

=over 4

=item (Str) current_perl

Return the "current perl" object attribute string, or, if absent, the value of
C<PERLBREW_PERL> environment variable.

=item (Str) current_perl (Str)

Set the C<current_perl> object attribute to the given value.

=back

=head2 PROJECT DEVELOPMENT

L<perlbrew project|https://perlbrew.pl/> uses github
L<https://github.com/gugod/App-perlbrew/issues> and RT
<https://rt.cpan.org/Dist/Display.html?Queue=App-perlbrew> for issue
tracking. Issues sent to these two systems will eventually be reviewed
and handled.

See L<https://github.com/gugod/App-perlbrew/contributors> for a list
of project contributors.

=head1 AUTHOR

Kang-min Liu  C<< <gugod@gugod.org> >>

=head1 COPYRIGHT

Copyright (c) 2010- Kang-min Liu C<< <gugod@gugod.org> >>.

=head3 LICENCE

The MIT License

=head2 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.

=cut
