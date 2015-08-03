package main;

use 5.010;
use strict;
use FindBin;
use lib "t/lib","lib","$FindBin::Bin/../blib/lib","$FindBin::Bin/../blib/arch";
use EV;
use Time::HiRes 'sleep','time';
use Scalar::Util 'weaken';
use Errno;
use EV::Tarantool16;
use Test::More;
use Test::Deep;
use Data::Dumper;
use Carp;
use Test::Tarantool16;
use Cwd;

my $tnt = {
	name => 'tarantool_tester',
	port => 3301,
	host => '127.0.0.1',
	username => 'test_user',
	password => 'test_pass',
	initlua => do {
		my $file = '/home/vagrant/EV-Tarantool16/provision/init.lua';
		local $/ = undef;
		open my $f, "<", $file
			or die "could not open $file: $!";
		my $d = <$f>;
		close $f;
		$d;
	}
};

$tnt = Test::Tarantool16->new(
	# cleanup => 0,
	title   => $tnt->{name},
	host    => $tnt->{host},
	port    => $tnt->{port},
	# logger  => sub { diag (map { (my $line =$_) =~ s{^}{$self->{name}: }mg } @_) if $ENV{TEST_VERBOSE}},
	# logger  => sub { },
	logger  => sub { diag ( $tnt->{title},' ', @_ )},
	initlua => $tnt->{initlua},
	# on_die  => sub { BAIL_OUT "Mock tarantool $self->{name} is dead!!!!!!!! $!"},
	on_die  => sub { fail "tarantool $tnt->{name} is dead!: $!"; exit 1; },
);

$tnt->start(timeout => 10, sub {
	my ($status, $desc) = @_;
	if ($status == 1) {
		say "connected";
		EV::unloop;
	}
});
EV::loop;

$tnt->admin_cmd("box.info", sub {
	say Dumper \@_;
	EV::unloop;
});
EV::loop;

