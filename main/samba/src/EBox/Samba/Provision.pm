# Copyright (C) 2013 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

package EBox::Samba::Provision;

use EBox::Exceptions::MissingArgument;
use EBox::Exceptions::InvalidType;
use EBox::Exceptions::External;
use EBox::Validate qw(:all);
use EBox::Gettext;
use EBox::Global;

use Net::DNS;
use Net::NTP qw(get_ntp_response);
use Net::Ping;
use Net::LDAP;
use Net::LDAP::Util qw(ldap_explode_dn);
use File::Temp qw( tempfile tempdir );
use File::Slurp;
use Error qw(:try);

use constant SAMBA_PROVISION_FILE => '/home/samba/.provisioned';

sub new
{
    my ($class, %params) = @_;
    my $self = {};
    bless ($self, $class);
    return $self;
}

sub isProvisioned
{
    my ($self) = @_;

    return EBox::Sudo::fileTest('-f', SAMBA_PROVISION_FILE);
}

sub setProvisioned
{
    my ($self, $provisioned) = @_;

    if ($provisioned) {
        EBox::Sudo::root("touch " . SAMBA_PROVISION_FILE);
    } else {
        EBox::Sudo::root("rm -f " . SAMBA_PROVISION_FILE);
    }
}

# Method: checkEnvironment
#
#   This method ensure that the environment is properly configured for
#   samba provision.
#
# Arguments:
#
#   throwException - 0 print warn on log, 1 throw exception
#
# Returns:
#
#   The IP address to use for provision
#
sub checkEnvironment
{
    my ($self, $throwException) = @_;

    unless (defined $throwException) {
        throw EBox::Exceptions::MissingArgument('throwException');
    }
    $self->_checkUsersState();

    # Get the own domain
    my $sysinfo    = EBox::Global->modInstance('sysinfo');
    my $hostDomain = $sysinfo->hostDomain();
    my $hostName   = $sysinfo->hostName();

    # Get the kerberos realm
    my $users = EBox::Global->modInstance('users');
    my $realm = $users->kerberosRealm();

    # The own domain and the kerberos realm must be equal
    my $samba = EBox::Global->modInstance('samba');
    unless (lc $hostDomain eq lc $realm) {
        $samba->enableService(0);
        my $err = __x("The host domain '{d}' has to be the same than the " .
                      "kerberos realm '{r}'", d => $hostDomain, r => $realm);
        if ($throwException) {
            throw EBox::Exceptions::External($err);
        } else {
            EBox::warn($err);
        }
    }

    # Check the domain exists in DNS module
    my $dns = EBox::Global->modInstance('dns');
    my $domainModel = $dns->model('DomainTable');
    my $domainRow = $domainModel->find(domain => $hostDomain);
    unless (defined $domainRow) {
        $samba->enableService(0);
        my $err = __x("The required domain '{d}' could not be found in the " .
                      "dns module.<br/>" .
                      "You can add it in the {ohref}DNS domains page{chref}",
                      d => $hostDomain,
                      ohref => "<a href='/DNS/Composite/Global'>",
                      chref => '</a>'
                     );
        if ($throwException) {
            throw EBox::Exceptions::External($err);
        } else {
            EBox::warn($err);
        }
    }

    # Check the hostname exists in the DNS module
    my $hostsModel = $domainRow->subModel('hostnames');
    my $hostRow = $hostsModel->find(hostname => $hostName);
    unless (defined $hostRow) {
        $samba->enableService(0);
        my $hostTableUrl = '/DNS/View/HostnameTable?directory=DomainTable/keys/' . $domainRow->id() .
                                                          '/hostnames';
        my $err = __x("The required host record '{h}' could not be found in " .
                      "the domain '{d}'.<br/>" .
                      "You can add it in the {ohref}host names page for domain {d}{chref}.",
                      h => $hostName,
                      d => $hostDomain,
                      ohref => "<a href='$hostTableUrl'>",
                      chref => '</a>'
                       );
        if ($throwException) {
            throw EBox::Exceptions::External($err);
        } else {
            EBox::warn($err);
        }
    }

    # Get the IP addresses for domain
    my %domainsIp = %{ $self->_domainsIP($samba, $domainRow, $throwException) };

    my $hostIPsModel = $hostRow->subModel('ipAddresses');
    # Get the IP address to use for provision, and check that this IP is assigned
    # to the domain
    my $provisionIP = undef;
    foreach my $rowId (@{$hostIPsModel->ids()}) {
        my $row = $hostIPsModel->row($rowId);
        my $ip = $row->valueByName('ip');
        if ($domainsIp{$ip}) {
            $provisionIP = $ip;
            last;
        }
    }

    unless (defined $provisionIP) {
        $samba->enableService(0);
        my $ipUrl = '/DNS/View/HostIpTable?directory=' .
                    'DomainTable/keys/' . $domainRow->id() .
                    '/hostnames/keys/' .  $hostRow->id() . '/ipAddresses';
        my $err = __x("Samba can't be provisioned if no internal IP addresses are set for host {host}.<br/>"  .
                      "Ensure that you have at least a IP address assigned to an internal interface, and this IP has to be " .
                       "assigned to the domain {dom} and to the hostname {host}.<br/>" .
                       "You can add it in the {ohref}IP addresses page for {host}{chref}",
                      host => $hostName,
                      dom  => $hostDomain,
                      ohref => "<a href='$ipUrl'>",
                      chref => '</a>'
                      );
        if ($throwException) {
            throw EBox::Exceptions::External($err);
        } else {
            EBox::warn($err);
        }
    }

    return $provisionIP;
}

sub _domainsIP
{
    my ($self, $samba, $domainRow, $throwException) = @_;

    my $domainIPsModel = $domainRow->subModel('ipAddresses');
    my @ipIds = @{$domainIPsModel->ids()};

    my $network = EBox::Global->modInstance('network');
    my $ifaces = $samba->sambaInterfaces();

    my %domainsIp;
    foreach my $iface (@{$ifaces}) {
        next if $iface eq 'lo';
        my $ifaceAddrs = $network->ifaceAddresses($iface);
        foreach my $data (@{$ifaceAddrs}) {
            # Got one candidate address, check that it is assigned to the DNS domain
            my $inDomainModel = 0;
            my $inHostModel = 0;
            foreach my $rowId (@ipIds) {
                my $row = $domainIPsModel->row($rowId);
                my $ip = $row->valueByName('ip');
                if ($ip eq $data->{address}) {
                    $domainsIp{$ip} = 1;
                }
            }
        }
    }

    if ((keys %domainsIp) == 0) {
        $samba->enableService(0);
        my $domain = $domainRow->valueByName('domain');
        my $domainIpUrl = '/DNS/View/DomainIpTable?directory=DomainTable/keys/' .
                          $domainRow->id() . '/ipAddresses';
        my $err = __x("Samba can't be provisioned if no internal IP addresses are set for domain {dom}.<br/>"  .
                      "Ensure that you have at least a IP address assigned to an internal interface, and this IP has to be " .
                       "assigned to the domain {dom} and to the local hostname.<br/>" .
                       "You can assign it in the {ohref}IP addresses page for {dom}{chref}",
                       dom => $domain,
                      ohref => "<a href='$domainIpUrl'>",
                      chref => '</a>'
                      );
        if ($throwException) {
            throw EBox::Exceptions::External($err);
        } else {
            EBox::warn($err);
        }
    }

    return \%domainsIp;
}

# Method: setupDNS
#
#   Modify the domain setup for samba or for users module
#
sub setupDNS
{
    my ($self) = @_;

    my $samba = EBox::Global->modInstance('samba');

    if (EBox::Sudo::fileTest('-f', $samba->SAMBA_DNS_KEYTAB())) {
        my @cmds;
        push (@cmds, "chgrp bind " . $samba->SAMBA_DNS_KEYTAB());
        push (@cmds, "chmod g+r " . $samba->SAMBA_DNS_KEYTAB());
        EBox::Sudo::root(@cmds);
    }
}

sub _checkUsersState
{
    my ($self) = @_;

    my $users = EBox::Global->modInstance('users');
    if ($users->master() eq 'zentyal') {
        throw EBox::Exceptions::External(
            __x('Cannot enable Samba because this server is synchronizing its users as slave of other Zentyal.' .
                '<br/>You can change this state at {ohref}synchronization options{chref}',
                ohref => q{<a href='/Users/Composite/Sync'>},
                chref => '</a>'
               )
           );
    }
}

# Method: provision
#
#   This method provision the database
#
sub provision
{
    my ($self) = @_;

    # Stop the service
    my $samba = EBox::Global->modInstance('samba');
    $samba->stopService();

    # Check environment
    my $provisionIP = $self->checkEnvironment(2);

    # Delete samba config file and private folder
    my @cmds;
    push (@cmds, 'rm -f ' . $samba->SAMBACONFFILE());
    push (@cmds, 'rm -rf ' . $samba->PRIVATE_DIR() . '/*');
    push (@cmds, 'rm -rf ' . $samba->SYSVOL_DIR() . '/*');
    EBox::Sudo::root(@cmds);

    my $mode = $samba->mode();
    if ($mode eq EBox::Samba::Model::GeneralSettings::MODE_DC()) {
        $self->provisionDC($provisionIP);
    } elsif ($mode eq EBox::Samba::Model::GeneralSettings::MODE_ADC()) {
        $self->provisionADC();
    } else {
        throw EBox::Exceptions::External(__x('The mode {mode} is not supported'), mode => $mode);
    }
}

sub resetSysvolACL
{
    my ($self) = @_;

    # Reset the sysvol permissions
    EBox::info("Reseting sysvol ACLs to defaults");
    my $cmd = "samba-tool ntacl sysvolreset";
    EBox::Sudo::rootWithoutException($cmd);
}

sub mapAccounts
{
    my ($self) = @_;

    my $sambaModule = EBox::Global->modInstance('samba');
    my $domainSID = $sambaModule->ldb->domainSID();

    # Map unix root account to domain administrator. The accounts are
    # imported to Zentyal here to avoid s4sync overwrite the uid/gid
    # mapping
    my $typeUID  = EBox::LDB::IdMapDb::TYPE_UID();
    my $typeGID  = EBox::LDB::IdMapDb::TYPE_GID();
    my $typeBOTH = EBox::LDB::IdMapDb::TYPE_BOTH();
    my $domainAdminSID = "$domainSID-500";
    my $domainAdminsSID = "$domainSID-512";
    my $rootUID = 0;
    my $admGID = 4;

    EBox::info("Mapping domain administrator account");
    my $domainAdmin = new EBox::Samba::User(sid => $domainAdminSID);
    $domainAdmin->addToZentyal() if ($domainAdmin->exists());
    $sambaModule->ldb->idmap->setupNameMapping($domainAdminSID, $typeUID, $rootUID);

    EBox::info("Mapping domain administrators group account");
    my $domainAdmins = new EBox::Samba::Group(sid => $domainAdminsSID);
    $domainAdmins->addToZentyal() if ($domainAdmins->exists());
    $sambaModule->ldb->idmap->setupNameMapping($domainAdminsSID, $typeBOTH, $admGID);

    # Map domain users group
    # FIXME Why is this not working during first intall???
    #my $usersModule = EBox::Global->modInstance('users');
    #my $usersGID = getpwnam($usersModule->DEFAULTGROUP());
    my $usersGID = 1901;
    my $domainUsersSID = "$domainSID-513";
    $sambaModule->ldb->idmap->setupNameMapping($domainUsersSID, $typeGID, $usersGID);

    # Map domain guest account to nobody user
    my $guestSID = "$domainSID-501";
    my $guestGroupSID = "$domainSID-514";
    #my $uid = getpwnam(EBox::Samba::Model::SambaShares::GUEST_DEFAULT_USER());
    #my $gid = getgrnam(EBox::Samba::Model::SambaShares::GUEST_DEFAULT_GROUP());
    my $uid = 65534;
    my $gid = 65534;
    EBox::info("Mapping domain guest account");
    $sambaModule->ldb->idmap->setupNameMapping($guestSID, $typeUID, $uid);
    EBox::info("Mapping domain guests group account");
    $sambaModule->ldb->idmap->setupNameMapping($guestGroupSID, $typeGID, $gid);
}

sub provisionDC
{
    my ($self, $provisionIP) = @_;

    my $samba = EBox::Global->modInstance('samba');
    $samba->writeSambaConfig();

    my $fs = EBox::Config::configkey('samba_fs');
    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $usersModule = EBox::Global->modInstance('users');
    my $cmd = 'samba-tool domain provision ' .
        " --domain='" . $samba->workgroup() . "'" .
        " --workgroup='" . $samba->workgroup() . "'" .
        " --realm='" . $usersModule->kerberosRealm() . "'" .
        " --dns-backend=BIND9_DLZ" .
        " --use-xattrs=yes " .
        " --use-rfc2307 " .
        " --server-role='" . $samba->mode() . "'" .
        " --users='" . $usersModule->DEFAULTGROUP() . "'" .
        " --host-name='" . $sysinfo->hostName() . "'" .
        " --host-ip='" . $provisionIP . "'";
    $cmd .= ' --use-ntvfs' if (defined $fs and $fs eq 'ntvfs');

    EBox::info("Provisioning database '$cmd'");
    $cmd .= " --adminpass='" . $samba->administratorPassword() . "'";

    # Use silent root to avoid showing the admin pass in the logs if
    # provision command fails.
    my $output = EBox::Sudo::silentRoot($cmd);
    if ($? == 0) {
        EBox::debug("Provision result: @{$output}");
    } else {
        my @error = ();
        my $stderr = EBox::Config::tmp() . 'stderr';
        if (-r $stderr) {
            @error = read_file($stderr);
        }
        throw EBox::Exceptions::Internal("Error provisioning database. Output: @{$output}, error:@error");
    };

    $self->setupDNS();
    $self->setProvisioned(1);

    try {
        # Disable password policy
        # NOTE complexity is disabled because when changing password in
        #      zentyal the command may fail if it do not meet requirements,
        #      ending with different passwords
        EBox::info('Setting password policy');
        $cmd = "samba-tool domain passwordsettings set " .
                           " --complexity=off "  .
                           " --min-pwd-length=0" .
                           " --min-pwd-age=0" .
                           " --max-pwd-age=365";
        EBox::Sudo::root($cmd);

        # Start managed service to let it create the LDAP socket
        $samba->_startService();

        # Load all zentyal users and groups into ldb
        $samba->ldb->ldapUsersToLdb();
        $samba->ldb->ldapGroupsToLdb();
        $samba->ldb->ldapServicePrincipalsToLdb();

        # Map accounts
        $self->mapAccounts();

        # Reset sysvol
        $self->resetSysvolACL();
    } otherwise {
        my ($error) = @_;
        $self->setProvisioned(0);
        throw EBox::Exceptions::External($error);
    };
}

sub rootDseAttributes
{
    my ($self) = @_;

    unless (defined $self->{rootDseAttributes}) {
        my $sambaModule = EBox::Global->modInstance('samba');
        my $rootDseAttributes = $sambaModule->ldb->ROOT_DSE_ATTRS();
        $self->{rootDseAttributes} = $rootDseAttributes;
    }
    return $self->{rootDseAttributes};
}

sub getADDomain
{
    my ($self, $adServerIp) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);

    my $adLdap = new Net::LDAP($adServerIp);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $defaultNC = $rootDse->get_value('defaultNamingContext');

    my $adDomain = $defaultNC;
    $adDomain =~ s/DC=//g;
    $adDomain =~ s/,/./g;

    unless (defined $adDomain) {
        throw EBox::Exceptions::External(
            __x('Could not determine the domain of the specified AD server {x}.',
                x => $adServerIp));
    }
    return $adDomain;
}

sub getADRealm
{
    my ($self, $adServerIp) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);

    my $adLdap = new Net::LDAP($adServerIp);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $ldapPrinc = $rootDse->get_value('ldapServiceName');
    my (undef, $adRealm) = split(/@/, $ldapPrinc);

    unless (defined $adRealm) {
        throw EBox::Exceptions::External(
            __x('Could not determine the realm of the specified AD server {x}.',
                x => $adServerIp));
    }
    return $adRealm;
}

sub bindToADLdap
{
    my ($self, $adServerIp, $adUser, $adPwd) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);
    throw EBox::Exceptions::MissingArgument('adUser')
        unless (defined $adUser and length $adUser);
    throw EBox::Exceptions::MissingArgument('adPwd')
        unless (defined $adPwd and length $adPwd);

    my $adDomain = $self->getADDomain($adServerIp);
    my $adLdap = new Net::LDAP($adServerIp);
    my $ldapMsg = $adLdap->bind("$adUser\@$adDomain", password => $adPwd);
    if ($ldapMsg->is_error()) {
        my $msg = __x('Could not bind to AD LDAP server ({x}).' .
                      'Please check the supplied credentials.',
                      x => $ldapMsg->error());
        throw EBox::Exceptions::External($msg);
    }
    return $adLdap;
}

# Method: checkDnsZonesInMainPartition
#
#   Checks that there aren't DNS zones stored in the main directory
#   partition (CN=MicrosoftDNS,CN=System,DC=...). On W2K the DomainDnsZones
#   and ForestDnsZones partitions didn't exists and zones were stored
#   there. The bind9 DLZ only has access to these partitions for security
#   reasons, so the DNS zones stored there must be moved to the DNS
#   partitions before join the domain. This is a corner case that only
#   affects when joinig to W2K (not supported) or servers upgraded from W2K
#
sub checkDnsZonesInMainPartition
{
    my ($self, $adServerIp, $adUser, $adPwd) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);
    throw EBox::Exceptions::MissingArgument('adUser')
        unless (defined $adUser and length $adUser);
    throw EBox::Exceptions::MissingArgument('adPwd')
        unless (defined $adPwd and length $adPwd);

    EBox::info("Checking for old DNS zones stored in main domain partition...");
    my $adLdap = $self->bindToADLdap($adServerIp, $adUser, $adPwd);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $defaultNC = $rootDse->get_value('defaultNamingContext');

    my $ldapMsg = $adLdap->search(base => "CN=MicrosoftDNS,CN=System,$defaultNC",
                                  scope => 'sub',
                                  filter => '(objectClass=dnsZone)',
                                  attrs => ['name']);
    my @zoneNames;
    foreach my $entry ($ldapMsg->entries) {
        my $zoneName = $entry->get_value('name');
        next if (lc ($zoneName) eq lc ('RootDNSServers') or
                 lc ($zoneName) eq lc ('..TrustAnchors'));
        push (@zoneNames, $zoneName);
    }

    if (scalar @zoneNames > 0) {
        my $zoneNames = join (', ', @zoneNames);
        my $link = 'http://technet.microsoft.com/en-us/library/cc730964';
        my $msg = __x('Could not join to domain. The following DNS zones are ' .
                      'stored in the main domain partition: {zones}. ' .
                      'This normally happen when the server is upgraded from ' .
                      'Windows Server 2000, and Samba4 will not be able to read ' .
                      'these zones. Please, move the zones to the ' .
                      '"DomainDnsZones" or "ForestDnsZones" and try again. ' .
                      'Check {link} for help on how to do that.',
                      zones => $zoneNames, link => $link);
        throw EBox::Exceptions::External($msg);
    }
}

# Method: checkForestDomains
#
#   Check that the forest only contains one domain
#
sub checkForestDomains
{
    my ($self, $adServerIp, $adUser, $adPwd) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);
    throw EBox::Exceptions::MissingArgument('adUser')
        unless (defined $adUser and length $adUser);
    throw EBox::Exceptions::MissingArgument('adPwd')
        unless (defined $adPwd and length $adPwd);

    EBox::info("Checking number of domains inside forest...");
    my $adLdap = $self->bindToADLdap($adServerIp, $adUser, $adPwd);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $configurationNC = $rootDse->get_value('configurationNamingContext');

    my $result = $adLdap->search(base => "CN=Partitions,$configurationNC",
                               scope => 'sub',
                               filter => '(objectClass=crossRef)',
                               attrs => ['systemFlags']);
    if ($result->code()) {
        throw EBox::Exceptions::External(
            __('Could not retrieve the domain information.'));
    }
    my $domainCount = 0;
    foreach my $entry ($result->entries()) {
        my $flags = $entry->get_value('systemFlags');
        $domainCount++ if ($flags & 0x00000002);
    }
    if ($domainCount > 1) {
        throw EBox::Exceptions::External(
        __('The AD forest contains more than one domain. Samba ' .
           'only support one domain per forest.'));
    }
    $adLdap->unbind();
}

# Method: checkServerReachable
#
#   Check that the AD server is alive and is reachable
#
sub checkServerReachable
{
    my ($self, $adServerIp) = @_;

    EBox::info("Checking if AD server '$adServerIp' is online...");
    my $pinger = new Net::Ping('tcp');
    $pinger->port_number(389);
    $pinger->service_check(1);
    unless ($pinger->ping($adServerIp)) {
        throw EBox::Exceptions::External(
            __x('The specified domain controller {x} is unreachable.',
                x => $adServerIp));
    }
    $pinger->close();
}

# If the host domain or the users kerberos realm does not
# match the domain we are trying to join warn the user and
# abort
sub checkLocalRealmAndDomain
{
    my ($self, $adServerIp) = @_;

    EBox::info("Checking local domain and realm...");
    my $usersModule = EBox::Global->modInstance('users');
    my $krbRealm = $usersModule->kerberosRealm();
    my $adRealm = $self->getADRealm($adServerIp);
    unless (uc ($krbRealm) eq uc ($krbRealm)) {
        throw EBox::Exceptions::External(
            __x('The local kerberos realm {x} must match the ' .
                'AD server realm {y}.', x => $krbRealm, y => $adRealm));
    }

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $hostDomain = $sysinfo->hostDomain();
    my $adDomain = $self->getADDomain($adServerIp);
    unless (lc ($hostDomain) eq lc ($adDomain)) {
        throw EBox::Exceptions::External(
            __x('The local domain {x} must match the AD server ' .
               'domain {y}.', x => $hostDomain, y => $adDomain));
    }
}

sub checkAddress
{
    my ($self, $adDnsServerIp, $adServerFQDN) = @_;

    throw EBox::Exceptions::MissingArgument('adDnsServerIp')
        unless (defined $adDnsServerIp and length $adDnsServerIp);
    throw EBox::Exceptions::MissingArgument('adServerFQDN')
        unless (defined $adServerFQDN and length $adServerFQDN);
    throw EBox::Exceptions::InvalidType('adDnsServerIp', 'IP Address')
        unless (EBox::Validate::checkIP($adDnsServerIp));

    my $adServerIp = undef;
    if (EBox::Validate::checkIP($adServerFQDN)) {
        $adServerIp = $adServerFQDN;
    } else {
        EBox::info("Resolving $adServerFQDN to an IP address");
        my $resolver = new Net::DNS::Resolver(nameservers => [$adDnsServerIp]);
        $resolver->tcp_timeout(5);
        $resolver->udp_timeout(5);
        my $answer = '';
        my $query = $resolver->query($adServerFQDN, 'A');
        if ($query) {
            foreach my $rr ($query->answer()) {
                next unless $rr->type() eq 'A';
                $answer = $rr->address();
                last;
            }
        }
        unless (defined $answer and length $answer) {
            throw EBox::Exceptions::External(
                __x('The DC {x} could not be resolved to its IP address. Please ' .
                    'check the specified server name and DNS server.',
                    x => $adServerFQDN));
        }
        $adServerIp = $answer;
        EBox::info("The DC $adServerFQDN has been resolved to $adServerIp");
    }

    EBox::info("Checking reverse DNS resolution of '$adServerIp'...");
    my $answer = '';
    my $resolver = new Net::DNS::Resolver(nameservers => ['127.0.0.1']);
    $resolver->tcp_timeout(5);
    $resolver->udp_timeout(5);
    my $target = join('.', reverse split(/\./, $adServerIp)).".in-addr.arpa";
    my $query = $resolver->query($target, 'PTR');
    if ($query) {
        foreach my $rr ($query->answer()) {
            next unless $rr->type() eq 'PTR';
            $answer = $rr->ptrdname();
            last;
        }
    }

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    if (lc ($answer) eq lc ($sysinfo->fqdn())) {
        throw EBox::Exceptions::External(
            __x('The specified AD server is registered on the local DNS as ' .
                '{x}, which matches local host name.', x => $answer));
    }
    if (defined $answer and length $answer) {
        EBox::info("The IP address $adServerIp has been resolved to $answer");
    } else {
        EBox::info("The IP address $adServerIp does not have associated PTR record");
    }
    return $adServerIp;
}

sub checkFunctionalLevels
{
    my ($self, $adServerIp) = @_;

    EBox::info("Checking forest and domain functional levels...");
    my $adLdap = new Net::LDAP($adServerIp);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $forestLevel = $rootDse->get_value('forestFunctionality');
    unless ($forestLevel >= 2) {
        throw EBox::Exceptions::External(
            __('The forest functional level must be Windows Server 2003 ' .
               'or higher. Please raise your forest functional level.'));
    }
    my $domainLevel = $rootDse->get_value('domainFunctionality');
    unless ($domainLevel >= 2) {
        throw EBox::Exceptions::External(
            __('The domain functional level must be Windows Server 2003 ' .
               'or higher. Please raise your domain functional level.'));
    }
}

sub checkTrustDomainObjects
{
    my ($self, $adServerIp, $adUser, $adPwd) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);
    throw EBox::Exceptions::MissingArgument('adUser')
        unless (defined $adUser and length $adUser);
    throw EBox::Exceptions::MissingArgument('adPwd')
        unless (defined $adPwd and length $adPwd);

    EBox::info("Checking for domain trust relationships...");
    my $adLdap = $self->bindToADLdap($adServerIp, $adUser, $adPwd);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $defaultNC = $rootDse->get_value('defaultNamingContext');

    my $ldapMsg = $adLdap->search(base => "CN=System,$defaultNC",
                                  scope => 'sub',
                                  filter => '(objectClass=trustedDomain)',
                                  attrs => ['*']);
    if ($ldapMsg->count() > 0) {
        throw EBox::Exceptions::External(
            __('The domain you are trying to join has trust relationships defined. ' .
               'At the moment this is not supported by samba.'));
    }
}

# Method: checkClockSkew
#
#   Checks the clock skew with the remote AD server and throw exception
#   if the offset is above two minutes.
#
#   Maths:
#       Originate Timestamp     T1 - time request sent by client
#       Receive Timestamp       T2 - time request received by server
#       Transmit Timestamp      T3 - time reply sent by server
#       Destination Timestamp   T4 - time reply received by client
#
#       The roundtrip delay d and local clock offset t are defined as:
#       d = (T4 - T1) - (T2 - T3)
#       t = ((T2 - T1) + (T3 - T4)) / 2
#
sub checkClockSkew
{
    my ($self, $adServerIp) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);

    my %h;
    try {
        EBox::info("Checking clock skew with AD server...");
        %h = get_ntp_response($adServerIp);
    } otherwise {
        throw EBox::Exceptions::External(
            __x('Could not retrive time from AD server {x} via NTP.',
                x => $adServerIp));
    };

    my $t0 = time;
    my $T1 = $t0; # $h{'Originate Timestamp'};
    my $T2 = $h{'Receive Timestamp'};
    my $T3 = $h{'Transmit Timestamp'};
    my $T4 = time; # From Time::HiRes
    my $d = ($T4 - $T1) - ($T2 - $T3);
    my $t = (($T2 - $T1) + ($T3 - $T4)) / 2;
    unless (abs($t) < 120) {
        throw EBox::Exceptions::External(
            __('The clock skew with the AD server is higher than two minutes. ' .
               'This can cause problems with kerberos authentication, please ' .
               'sync both clocks with an external NTP source and try again.'));
    }
    EBox::info("Clock skew below two minutes, should be enought.");
}

sub checkADServerSite
{
    my ($self, $adServerIp, $adUser, $adPwd, $site) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);
    throw EBox::Exceptions::MissingArgument('adUser')
        unless (defined $adUser and length $adUser);
    throw EBox::Exceptions::MissingArgument('adPwd')
        unless (defined $adPwd and length $adPwd);

    my $adLdap = $self->bindToADLdap($adServerIp, $adUser, $adPwd);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $adServerSite = undef;

    if (defined $site and length $site) {
        # If the user has specified a site, check it exists
        EBox::info("Checking if the specified site $site exists in the domain");
        my $configurationNC = $rootDse->get_value('configurationNamingContext');
        my $ldapMsg = $adLdap->search(base => "CN=Sites,$configurationNC",
                                      scope => 'sub',
                                      filter => '(objectClass=site)',
                                      attrs => ['name']);
        foreach my $entry ($ldapMsg->entries()) {
            my $name = $entry->get_value('name');
            if (lc ($name) eq lc ($site)) {
                $adServerSite = $name;
                last;
            }
        }
        unless (defined $adServerSite) {
            throw EBox::Exceptions::External(
                __x("The specified site {x} does not exists on the domain.",
                    x => $site));
        }
        EBox::info("The site $site has been found in the domain");
    } else {
        # Search the site of the given server
        EBox::info("Checking the site where the specified server is located");
        my $serverNameDn = $rootDse->get_value('serverName');
        my $dnParts = ldap_explode_dn($serverNameDn, reverse => 0);
        $adServerSite = @{$dnParts}[2]->{CN};
        unless (defined $adServerSite) {
            throw EBox::Exceptions::External(
                __("Could not determine the site of the specified server"));
        }
        EBox::info("The specified server has been located at site named $adServerSite");
    }

    return $adServerSite;
}

sub checkADNebiosName
{
    my ($self, $adServerIp, $adUser, $adPwd, $netbios) = @_;

    throw EBox::Exceptions::MissingArgument('adServerIp')
        unless (defined $adServerIp and length $adServerIp);
    throw EBox::Exceptions::MissingArgument('adUser')
        unless (defined $adUser and length $adUser);
    throw EBox::Exceptions::MissingArgument('adPwd')
        unless (defined $adPwd and length $adPwd);

    EBox::info("Checking domain netbios name...");
    my $adLdap = $self->bindToADLdap($adServerIp, $adUser, $adPwd);
    my $rootDse = $adLdap->root_dse(attrs => $self->rootDseAttributes());
    my $configurationNC = $rootDse->get_value('configurationNamingContext');
    my $result = $adLdap->search(base => "CN=Partitions,$configurationNC",
                                 scope => 'sub',
                                 filter => '(nETBIOSName=*)',
                                 attrs => ['nETBIOSName']);
    my $adNetbiosDomain = undef;
    if ($result->count() == 1) {
        my $entry = $result->entry(0);
        $adNetbiosDomain = $entry->get_value('nETBIOSName');
    }
    unless (defined $adNetbiosDomain) {
        throw EBox::Exceptions::External(
            __("Could not determine the netbios domain name."));
    }
    unless (uc ($adNetbiosDomain) eq uc ($netbios)) {
        throw EBox::Exceptions::External(
            __x('The netBIOS name {x} could not be found. Please check ' .
                'the specified value.', x => $netbios));
    }
    return $adNetbiosDomain;
}

# FIXME This should not be necessary, it is a samba bug.
sub fixDnsSPN
{
    my ($self) = @_;

    my $samba = EBox::Global->modInstance('samba');
    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $fqdn = $sysinfo->fqdn();
    my $ucHostname = uc ($sysinfo->hostName());

    my @cmds = ();
    push (@cmds, "rm -f " . $samba->SAMBA_DNS_KEYTAB());
    push (@cmds, "samba-tool spn add DNS/$fqdn $ucHostname\$");
    push (@cmds, "samba-tool domain exportkeytab " .
                 $samba->SAMBA_DNS_KEYTAB() .
                 " --principal=$ucHostname\$");
    push (@cmds, "samba-tool domain exportkeytab " .
                 $samba->SAMBA_DNS_KEYTAB() .
                 " --principal=DNS/$fqdn");
    push (@cmds, "chgrp bind " . $samba->SAMBA_DNS_KEYTAB());
    push (@cmds, "chmod g+r " . $samba->SAMBA_DNS_KEYTAB());
    EBox::Sudo::root(@cmds);
}

sub provisionADC
{
    my ($self) = @_;

    my $sambaModule = EBox::Global->modInstance('samba');
    my $model = $sambaModule->model('GeneralSettings');
    my $domainToJoin = lc ($model->value('realm'));
    my $dcFQDN = $model->value('dcfqdn');
    my $adDnsServer = $model->value('dnsip');
    my $adUser = $model->value('adminAccount');
    my $adPwd = $model->value('password');
    my $netbiosDomain = $model->value('workgroup');
    my $site = $model->value('site');

    my $usersModule = EBox::Global->modInstance('users');
    my $realm = $usersModule->kerberosRealm();

    # Resolve DC FQDN to an IP if needed
    my $adServerIp = $self->checkAddress($adDnsServer, $dcFQDN);

    # Check DC is reachable
    $self->checkServerReachable($adServerIp);

    # Check DC functional levels > 2000
    $self->checkFunctionalLevels($adServerIp);

    # Check local realm matchs remote one
    $self->checkLocalRealmAndDomain($adServerIp);

    # Check clock skew
    $self->checkClockSkew($adServerIp);

    # Check no DNS zones in main domain partition
    $self->checkDnsZonesInMainPartition($adServerIp, $adUser, $adPwd);

    # Check forest only contains one domain
    $self->checkForestDomains($adServerIp, $adUser, $adPwd);

    # Check there are not trust relationships between domains or forests
    $self->checkTrustDomainObjects($adServerIp, $adUser, $adPwd);

    # Check the AD site
    my $adServerSite = $self->checkADServerSite($adServerIp, $adUser, $adPwd, $site);

    # Check the netbios domain name
    my $adNetbiosDomain = $self->checkADNebiosName($adServerIp, $adUser, $adPwd, $netbiosDomain);

    my $dnsFile = undef;
    my $adminAccountPwdFile = undef;
    try {
        EBox::info("Joining to domain '$domainToJoin' as DC");
        # Set the domain DNS as the primary resolver. This will also let to get
        # the kerberos ticket for the admin account.
        EBox::debug("Setting domain DNS server '$adDnsServer' as the primary resolver");
        $dnsFile = new File::Temp(TEMPLATE => 'resolvXXXXXX',
                                  DIR      => EBox::Config::tmp());
        EBox::Sudo::root("cp /etc/resolv.conf $dnsFile");
        my $array = [];
        push (@{$array}, searchDomain => $domainToJoin);
        push (@{$array}, nameservers => [ $adDnsServer ]);
        $sambaModule->writeConfFile(EBox::Network::RESOLV_FILE(),
                                    'network/resolv.conf.mas',
                                    $array);

        # Get a ticket for admin User
        my $principal = "$adUser\@$realm";
        (undef, $adminAccountPwdFile) = tempfile(EBox::Config::tmp() . 'XXXXXX', CLEANUP => 1);
        EBox::info("Trying to get a kerberos ticket for principal '$principal'");
        write_file($adminAccountPwdFile, $adPwd);
        my $cmd = "kinit -e arcfour-hmac-md5 --password-file='$adminAccountPwdFile' $principal";
        EBox::Sudo::root($cmd);

        # Write config
        $sambaModule->writeSambaConfig();

        # Join the domain
        EBox::info("Executing domain join");
        my $cmd2 = "samba-tool domain join $domainToJoin DC " .
                   " --username='$adUser' " .
                   " --workgroup='$netbiosDomain' " .
                   " --password='$adPwd' " .
                   " --server='$adServerIp' " .
                   " --dns-backend=BIND9_DLZ " .
                   " --realm='$realm' " .
                   " --site='$adServerSite' ";

        my $output = EBox::Sudo::silentRoot($cmd2);
        if ($? == 0) {
            EBox::debug("Provision result: @{$output}");
        } else {
            my @error;
            my $stderr = EBox::Config::tmp() . 'stderr';
            if (-r $stderr) {
                @error = read_file($stderr);
            }
            throw EBox::Exceptions::External("Error joining to domain: @error");
        }
        $self->fixDnsSPN();
        $self->setupDNS();

        $self->setProvisioned(1);

        # Start managed service to let it create the LDAP socket
        EBox::debug('Starting service');
        $sambaModule->_startService();

        # Wait some time until samba is ready
        sleep (5);

        # Run samba_dnsupdate to add required records to the remote DC
        EBox::info('Running DNS update on remote DC');
        $cmd = 'samba_dnsupdate --no-credentials';
        EBox::Sudo::rootWithoutException($cmd);

        # Run Knowledge Consistency Checker (KCC) on remote DC
        EBox::info('Running KCC on remote DC');
        $cmd = "samba-tool drs kcc $dcFQDN " .
            " --username='$adUser' " .
            " --password='$adPwd' ";
        EBox::Sudo::rootWithoutException($cmd);

        # Purge users and groups
        EBox::info("Purging the Zentyal LDAP to import Samba users");
        my $users = $usersModule->users();
        my $groups = $usersModule->groups();
        foreach my $zentyalUser (@{$users}) {
            $zentyalUser->setIgnoredModules(['samba']);
            $zentyalUser->deleteObject();
        }
        foreach my $zentyalGroup (@{$groups}) {
            $zentyalGroup->setIgnoredModules(['samba']);
            $zentyalGroup->deleteObject();
        }

        # Load Zentyal service principals into samba
        $sambaModule->ldb->ldapServicePrincipalsToLdb();

        # Map accounts
        $self->mapAccounts();

        EBox::debug('Setting provisioned flag');
        $self->setProvisioned(1);
    } otherwise {
        my ($error) = @_;
        $self->setProvisioned(0);
        $self->setupDNS();
        throw $error;
    } finally {
        # Revert primary resolver changes
        if (defined $dnsFile and -f $dnsFile) {
            EBox::Sudo::root("cp $dnsFile /etc/resolv.conf");
            unlink $dnsFile;
        }
        # Remote stashed password
        if (defined $adminAccountPwdFile and -f $adminAccountPwdFile) {
            unlink $adminAccountPwdFile;
        }
        # Destroy cached tickets
        EBox::Sudo::rootWithoutException('kdestroy');
    };
}

1;
