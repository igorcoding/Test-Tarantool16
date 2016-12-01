%define __autobuild__ 0
%define use_scl 0
%if %{use_scl}
%global scl %{use_scl}
%endif

%if %{__autobuild__}
%define version PKG_VERSION
%else
%define version 0.01
%endif
%define release %(/bin/date +"%Y%m%d.%H%M")
%define centos %(awk '/CentOS release [0-9]/ {print substr ($3,1,1)}' /etc/issue)

%global         _distribution Test-Tarantool16
%{?scl:%scl_package package_name}
%{!?scl:%global pkg_name %{_distribution}}

Name:           %{?scl_prefix}perl-%{_distribution}
Version:        %{version}
Release:        %{release}
Summary:        Test::Tarantool extention
License:        GPL+
Group:          Development/Libraries
URL:            http://search.cpan.org/dist/Test-Tarantool-Dir/
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
BuildRequires:  perl >= 0:5.006
BuildRequires:  %{?scl_prefix}perl(ExtUtils::MakeMaker)
BuildRequires:  %{?scl_prefix}perl(YAML::XS)
BuildRequires:  %{?scl_prefix}perl(Test::More)
BuildRequires:  %{?scl_prefix}perl(Proc::ProcessTable)
BuildRequires:  %{?scl_prefix}perl(File::Path)
BuildRequires:  %{?scl_prefix}perl(File::Spec)
BuildRequires:  %{?scl_prefix}perl(Data::Dumper)
BuildRequires:  %{?scl_prefix}perl(AnyEvent)
Requires:       %{?scl_prefix}perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
%{?scl:Requires: %scl_runtime}

%if %{__autobuild__}
Packager: BUILD_USER
Source0: %{_distribution}-GIT_TAG.tar.bz2
%else
Source0:        %{_distribution}-%{version}.tar.gz
%endif

%description
Test::Tarantool extention with EV::Tarantool client attached.
Spaces configuration and lua files managed from crafted a directory 
structure.
%{lua:
if rpm.expand("%{__autobuild__}") == '1'
then
print("From tag: GIT_TAG\n")
print("Git hash: GITHASH\n")
print("Build by: BUILD_USER\n")
end}

%prep
echo ======================= %{SOURCE0} ${Source0}
pwd
ls -lAFh
%if %{__autobuild__}
%setup -q -n %{_distribution}
%else
%setup -q -n %{_distribution}-%{version}
%endif

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
make %{?_smp_mflags}

%install
rm -rf $RPM_BUILD_ROOT

make pure_install PERL_INSTALL_ROOT=$RPM_BUILD_ROOT

find $RPM_BUILD_ROOT -type f -name .packlist -exec rm -f {} \;
find $RPM_BUILD_ROOT -depth -type d -exec rmdir {} 2>/dev/null \;

%{_fixperms} $RPM_BUILD_ROOT/*

%check
make test

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc META.json
%{perl_vendorlib}/*
%{_mandir}/man3/*

%changelog
* Fri Aug 28 2015 Maxim Polyakov 0.01-1
- Create spec based on Async::Chain spec
