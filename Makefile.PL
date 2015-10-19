use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

# unless ($^O eq 'linux') {
#     warn "This is Linux only software\n";
#     exit 0;
# }

my $preop =
    'perldoc -uT $(VERSION_FROM) | tee $(DISTVNAME)/README.pod > README.pod;' .
    'pod2text README.pod | tee $(DISTVNAME)/README > README';

WriteMakefile(
    NAME              => 'Test::Tarantool16',
    AUTHOR            => ['Anton Reznikov <a.reznikov@corp.mail.ru>', 'igorcoding <igorcoding@gmail.com>'],
    VERSION_FROM      => 'lib/Test/Tarantool16.pm',
    ABSTRACT_FROM     => 'lib/Test/Tarantool16.pm',
    LICENSE          => 'GPL',
    PREREQ_PM         => {
        'AnyEvent' => 0,
        'YAML::XS' => 0,
        'Proc::ProcessTable' => 0,
    },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', PREOP => $preop },
    clean => { FILES => 'Test-Tarantool-*' },
);
