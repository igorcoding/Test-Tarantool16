package Test::Tarantool16;

use 5.006;
use strict;
use warnings;
use IO::Handle qw/autoflush/;
use Scalar::Util 'weaken';
use AnyEvent::Handle;
use File::Path;
use File::Spec;
use Data::Dumper;
use YAML::XS;
use Proc::ProcessTable;

=head1 NAME

Test::Tarantool16 - The Swiss army knife for tests of Tarantool 1.6 related Perl and lua code.

=head1 VERSION

Version 0.033

=cut

our $VERSION = '0.033';
our $Count = 0;
our %Schedule;

=head1 SYNOPSIS

    use Test::Tarantool16;
    use AnyEvent;

    # Clear data and exit on Ctrl+C.
    my $w = AnyEvent->signal (signal => "INT", cb => sub { exit 0 });

    my @shards = map {
        my $n = $_;
        Test::Tarantool16->new(
            host => '127.17.3.0',
            initlua => do {
                          open my $f, '<', 'init.lua';
                          local $/ = undef;
                          <$f> or "";
                       },
            on_die => sub { warn "Shard #$n unexpectedly terminated\n"; exit; },
        );
    } 1..4;

    my @cluster = map { [ $_->{host}, $_->{p_port} ] } @shards;

    {
        my $cv = AE::cv();
        $cv->begin for (@shards);
        $_->start($cv) for (@shards);
        $cv->recv;
    }

    {
        $_->sync_start() for (@shards);
    }

    {
        my ($status, $reason) = $shards[0]->sync_ro();
        die $reason unless $status;
        print (($shards[0]->sync_admin_cmd("show info"))[1]);
    }

    # Some test case here

    $shards[1]->pause();

    # Some test case here

    $shards[1]->resume();

    {
        my ($status, $reason) = $shards[0]->sync_rw();
        die $reason unless $status;
        print (($shards[0]->sync_admin_cmd("show info"))[1]);
    }

    # stop tarantools and clear work directoies
    @shards = ();

=head1 SUBROUTINES/METHODS

=head2 new option => value,...

Create new Test::Tarantool16 instance. Every call of new method increase counter, below
called as I<tarantool number> or I<tn>.

=over 4

=item root => $path

Tarantool 1.6 work directory. Default is I<./tnt_E<lt>10_random_lowercase_lettersE<gt>>

=item arena => $size

The maximal size of tarantool arena in Gb. Default is I<0.1>

=item cleanup => $bool

Remove tarantool work directory after garbage collection. Default is I<1>

=item initlua => $content

Content of init.lua file. Be default an empty file created.

=item host => $address

Address bind to. Default: I<127.0.0.1>

=item port => $port

Primary port number. Default is I<3301+E<lt>tnE<gt>*4>

=item admin_port => $admin_port

Admin port number. Default is C<$port * 10>

=item title => $title

Part of process name (custom_proc_title) Default is I<"yatE<lt>tnE<lt>">

=item wal_mode => $mode

The WAL write mode. See the desctiption of wal_mode tarantool variable. Default
is I<none>. Look more about wal_mode in tarantool documentation.

=item log_level => $number

Tarantool log level. Default is I<5>

=item snapshot => $path

Path to some snapshot. If given the symbolic link to it will been created in
tarantool work directory.

=item replication_source => $string

If given the server is considered to be a Tarantool replica.

=item logger => $sub

An subroutine called at every time, when tarantool write some thing in a log.
The writed text passed as the first argument. Default is warn.

=item on_die => $sub

An subroutine called on a unexpected tarantool termination.

=item tarantool_cmd => $tarantool_cmd

Command that should start tarantool instance. Parameterized with %{args}.
All necessary arguments will be substitued into %{args}

=back

=cut

sub new {
	my $class = shift; $class = (ref $class)? ref $class : $class;
	my $self = {
		arena => 0.1,
		cleanup => 1,
		initlua => '-- init.lua --',
		host => '127.0.0.1',
		log_level => 5,
		logger => sub { warn $_[0] },
		on_die => sub { warn "Broken pipe, child is dead?"; },
		port => 3301 + $Count, # FIXME: auto fitting needed
		admin_port => (3301 + $Count) * 10,
		replication_source => '',
		root => join("", ("tnt_", map { chr(97 + int(rand(26))) } 1..10)),
		snapshot => '',
		title => "yat" . $Count,
		wal_mode => 'none',
		tarantool_cmd => 'tarantool %{args}',
		@_,
	}; $Count++;

	bless $self, $class;

	weaken ($Schedule{$self} = $self);

	mkdir($self->{root}) or die "Couldn't create folder $self->{root}: $!";
	$self->_config();
	$self;
}

=head2 start option => $value, $cb->($status, $reason)

Run tarantool instance.

=over 4

=item timeout => $timeout

If not After $timeout seconds tarantool will been killed by the KILL signal if
not started.

=back

=cut

sub start {
	my $self = shift;
	my $cb = pop;
	my %arg = (
		timeout => 60,
		@_
	);

	return $cb->(0, 'Already running') if($self->{pid});

	pipe my $cr, my $pw or die "pipe filed: $!";
	pipe my $pr, my $cw or die "pipe filed: $!";
	autoflush($_) for ($pr, $pw, $cr, $cw);

	return $cb->(0, "Can't fork: $!") unless defined(my $pid = fork);
	if ($pid) {
		close($_) for ($cr, $cw);
		$self->{pid} = $pid;
		$self->{rpipe} = $pr;
		$self->{wpipe} = $pw;
		$self->{nanny} = AnyEvent->child(
			pid => $pid,
			cb => sub {
				$self->{$_} = undef for qw/pid asleep rpipe wpipe nanny/;
				# call on_die only for unexpected termination
				if($self->{dying}) {
					delete $self->{dying};
				} else {
					$self->{on_die}->($self, @_);
				}
			});
		$self->{rh} = AnyEvent::Handle->new(
			fh => $pr,
			on_read => sub { $self->{logger}->(delete $_[0]->{rbuf}) },
			on_error => sub {
				kill 9, $self->{pid} if ($self->{pid} and kill 0, $self->{pid});
			},
		);
		my $i = int($arg{timeout} / 0.1);
		$self->{start_timer} = AnyEvent->timer(
			after => 0.01,
			interval => 0.1,
			cb => sub {
				unless ($self->{pid}) {
					$self->{start_timer} = undef;
					return $cb->(0, "Process unexpectedly terminated");
				}
				my ($status, $message) = $self->_process_check();
				if (defined($status) && defined($message)) {
					$self->{start_timer} = undef;
					return $cb->($status, $message);
				}
				unless($i > 0) {
					kill TERM => $self->{pid};
					$self->{start_timer} = undef;
					$cb->(0, "Timeout exceeding. Process terminated");
				}
				$i--;
			}
		);
	} else {
		close($_) for ($pr, $pw);
		chdir $self->{root};
		open(STDIN, "<&", $cr) or die "Could not dup filehandle: $!";
		open(STDOUT, ">&", $cw) or die "Could not dup filehandle: $!";
		open(STDERR, ">&", $cw) or die "Could not dup filehandle: $!";
		my $file = File::Spec->rel2abs("./evtnt.lua");
		$self->{tarantool_cmd} =~ s/%\{([^{}]+)\}/$file/;
		exec($self->{tarantool_cmd});
		die "exec: $!";
	}
}

=head2 stop option => $value, $cb->($status, $reason)

stop tarantool instance

=over 4

=item timeout => $timeout

After $timeout seconds tarantool will been kelled by the KILL signal

=back

=cut

sub stop {
	my $self = shift;
	my $cb = pop;
	my %arg = (
		timeout => 10,
		@_
	);

	return $cb->(1, "Not Running") unless $self->{pid};

	$self->resume() if delete $self->{asleep};

	$self->{dying} = 1;

	my $i = int($arg{timeout} / 0.1);
	$self->{stop_timer} = AnyEvent->timer(
		interval => 0.1,
		cb => sub {
			unless ($self->{pid}) {
				$self->{stop_timer} = undef;
				$cb->(1, "OK");
			}

			unless($i > 0) {
				$self->{stop_timer} = undef;
				kill KILL => $self->{pid};
				$cb->(0, "Killed");
			}
			$i--;
		}
	);
	kill TERM => $self->{pid};
}

=head2 pause

Send STOP signal to instance

=cut

sub pause {
	my $self = shift;
	return unless $self->{pid};
	$self->{asleep} = 1;
	kill STOP => $self->{pid};
}

=head2 resume

Send CONT signal to instance

=cut

sub resume {
	my $self = shift;
	return unless $self->{pid};
	$self->{asleep} = undef;
	kill CONT => $self->{pid};
}

# =head2 ro $cb->($status, $reason)

# Switch tarantool instance to read only mode.

# =cut

# sub ro {
# 	my ($self, $cb) = @_;
# 	return $cb->(1, "Not Changed") if $self->{replication_source};
# 	$self->{replication_source} = "$self->{host}:$self->{port}";
# 	$self->_config();
# 	$self->admin_cmd("reload configuration", sub {
# 		$cb->($_[0], $_[0] ? "OK" : "Failed")
# 	});
# }

# =head2 rw $cb->($status, $reason)

# Switch tarantool instance to write mode.

# =cut

# sub rw {
# 	my ($self, $cb) = @_;
# 	return $cb->(1, "Not Changed") unless $self->{replication_source};
# 	$self->{replication_source} = "";
# 	$self->_config();
# 	$self->admin_cmd("reload configuration", sub {
# 		$cb->($_[0], $_[0] ? "OK" : "Failed")
# 	});
# }

=head2 admin_cmd $cmd, $cb->($status, $response_or_reason)

Exec a command via the admin port.

=cut

sub admin_cmd {
	my ($self, $cmd, $cb) = @_;
	return if ($self->{afh});
	$self->{afh} = AnyEvent::Handle->new (
		connect => [ $self->{host}, $self->{admin_port} ],
		on_connect => sub {
			my $hdl = $_[0];
			$hdl->push_read(regex => qr/Tarantool .*\n.*\n/, sub {
				$_[0]->rbuf = '';
				$_[0]->push_write($cmd . "\n");

				$self->{afh}->push_read(regex => qr/^(---\n.*\n?\.\.\.\n)$/s, sub {
					$_[0]->destroy();
					delete $self->{afh};
					my $resp = Load $1;
					$cb->(1, $resp);
				});
			});
		},
		on_connect_error => sub {
			$self->{logger}->("Connection error: $_[1]");
			$_[0]->on_read(undef);
			$_[0]->destroy();
			delete $self->{afh};
			$cb->(0, $_[1]);
		},
		on_error => sub {
			$_[0]->on_read(undef);
			$_[0]->destroy();
			delete $self->{afh};
			$cb->(0, $_[2])
		},
	);
}

=head2 times

Return values of utime and stime from /proc/[pid]/stat, converted to seconds

=cut

sub times {
	my $self = shift;
	return unless $self->{pid};
	open my $f, "<", "/proc/$self->{pid}/stat";
	map { $_ / 100 } (split " ", <$f>)[13..14];
}

=head2 sync_start sync_stop sync_admin_cmd

Aliases for start, stop, admin_cmd respectively, arguments a similar,
but cb not passed.

=cut

{
	no strict 'refs';
	for my $method (qw/start stop ro rw admin_cmd/) {
		*{"Test::Tarantool16::sync_$method"} = sub {
			my $self = shift;
			my $cv = AE::cv();
			$self->$method(@_, $cv);
			return $cv->recv;
		}
	}
}

sub _process_check {
	my $self = shift;
	my $cb = pop;
	
	my $t = Proc::ProcessTable->new();
	my $status = "running";
	for my $p ( @{$t->table} ){
		if ($p->pid == $self->{pid}) {
			my $ps = $p->cmndline;
			$self->{logger}->("Tarantool status check: pid=$self->{pid} cmdline=$ps");
			if ($ps =~ /$status/) {
				return 1, "OK";
			}
			last;
		}
	}
	return;
}

sub _config {
	my $self = shift;
	my $config = do { my $pos = tell DATA; local $/; my $c = <DATA>; seek DATA, $pos, 0; $c };
	$config =~ s/ %\{([^{}]+)\} /$self->{$1}/xsg;
	$config =~ s/ %\{\{(.*?)\}\} /eval "$1" or ''/exsg;
	open my $f, '>', $self->{root} . '/' . 'evtnt.lua' or die "Could not create tnt config : $!";;
	syswrite $f, $config;
}

sub DESTROY {
	my $self = shift;
	return unless $Schedule{$self};
	kill TERM => $self->{pid} if $self->{pid};
	if ($self->{cleanup}) {
		rmtree($self->{root}) or $self->{logger}->("Couldn't remove folder $self->{root}: $!");
	}
	delete $Schedule{$self};
	$self->{logger}->("$self->{title} destroyed\n");
}

END {
	for (keys %Schedule) {
		$Schedule{$_}->DESTROY();
	}
}

=head1 AUTHOR

Anton Reznikov, C<< <anton.n.reznikov at gmail.com> >>
igorcoding, C<< <igorcoding at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests in L<https://github.com/igorcoding/Test-Tarantool16/issues>


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Test::Tarantool16

=head1 ACKNOWLEDGEMENTS

    Mons Anderson    - The original idea of the module.

=head1 LICENSE AND COPYRIGHT

Copyright 2015 igorcoding.

This program is released under the following license: GPL

=cut

1;

__DATA__
box.cfg{
	custom_proc_title = "%{title}",
	slab_alloc_arena = %{arena},
	listen = "%{host}:%{port}",
	%{{ "replication_source = %{replication_source}," if "%{replication_source}" }}
	work_dir = ".",
	wal_mode = "%{wal_mode}",
	log_level = %{log_level}
}

box.schema.user.grant('guest','read,write,execute','universe')

require('console').listen('%{host}:%{admin_port}')

%{{ $self->{initlua} }}
