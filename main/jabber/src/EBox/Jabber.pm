# Copyright (C) 2010-2012 eBox Technologies S.L.
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

package EBox::Jabber;
use base qw(EBox::Module::Service EBox::LdapModule EBox::SysInfo::Observer);

use EBox::Global;
use EBox::Gettext;
use EBox::JabberLdapUser;
use EBox::Exceptions::DataExists;
use Error qw(:try);

use constant EJABBERDCONFFILE => '/etc/ejabberd/ejabberd.cfg';
use constant JABBERPORT => '5222';
use constant JABBERPORTSSL => '5223';
use constant JABBERPORTS2S => '5269';
use constant JABBERPORTSTUN => '3478';
use constant JABBERPORTPROXY => '7777';
use constant EJABBERD_CTL => '/usr/sbin/ejabberdctl';
use constant EJABBERD_DB_DIR =>  '/var/lib/ejabberd';

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'jabber',
                                      printableName => 'Jabber',
                                      @_);
    bless($self, $class);
    return $self;
}

# Method: actions
#
#   Override EBox::Module::Service::actions
#
sub actions
{
    return [
        {
            'action' => __('Add Jabber LDAP schema'),
            'reason' => __('Zentyal will need this schema to store Jabber users.'),
            'module' => 'jabber'
        },
    ];
}

# Method: usedFiles
#
#   Override EBox::Module::Service::usedFiles
#
sub usedFiles
{
    return [
        {
            'file' => EJABBERDCONFFILE,
            'module' => 'jabber',
            'reason' => __('To properly configure ejabberd.')
        },
    ];
}

# Method: initialSetup
#
# Overrides:
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Create default rules and services
    # only if installing the first time
    unless ($version) {
        my $services = EBox::Global->modInstance('services');

        my $serviceName = 'jabber';
        unless($services->serviceExists(name => $serviceName)) {
            $services->addMultipleService(
                'name' => $serviceName,
                'printableName' => 'Jabber',
                'description' => __('Jabber Server'),
                'internal' => 1,
                'readOnly' => 1,
                'services' => $self->_services(),
            );
        }

        my $firewall = EBox::Global->modInstance('firewall');
        $firewall->setExternalService($serviceName, 'deny');
        $firewall->setInternalService($serviceName, 'accept');

        $firewall->saveConfigRecursive();
    }
}

sub _services
{
    return [
             { # jabber c2s
                 'protocol' => 'tcp',
                 'sourcePort' => 'any',
                 'destinationPort' => '5222',
             },
             { # jabber c2s
                 'protocol' => 'tcp',
                 'sourcePort' => 'any',
                 'destinationPort' => '5223',
             },
    ];
}

# Method: enableActions
#
#   Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    $self->performLDAPActions();

    # Execute enable-module script
    $self->SUPER::enableActions();
}

#  Method: _daemons
#
#   Override <EBox::Module::Service::_daemons>
#
sub _daemons
{
    return [
        {
            'name' => 'ejabberd',
            'type' => 'init.d',
            'pidfiles' => ['/var/run/ejabberd/ejabberd.pid']
        }
    ];
}


# overriden because ejabberd process could be up and not be running
sub isRunning
{
    my ($self) = @_;
    my $stateCmd = 'LANG=C '. EJABBERD_CTL . ' status';
    my $output;
    try {
        $output =  EBox::Sudo::root($stateCmd);
    } catch EBox::Exceptions::Sudo::Command with {
        # output will be undef
    };

    if (not $output) {
        return 0;
    }

    foreach my $line (@{ $output }) {
        if ($line =~ m/is running in that node/) {
            return 1;
        }
    }

    return 0;
}

# Method: _setConf
#
#       Overrides base method. It writes the jabber service configuration
#
sub _setConf
{
    my ($self) = @_;

    my @array = ();

    my $jabuid = (getpwnam('ejabberd'))[2];
    my $jabgid = (getpwnam('ejabberd'))[3];

    my $users = EBox::Global->modInstance('users');
    my $ldap = $users->ldap();
    my $ldapconf = $ldap->ldapConf;

    my $settings = $self->model('GeneralSettings');
    my $jabberldap = new EBox::JabberLdapUser;

    push(@array, 'ldapHost' => '127.0.0.1');
    push(@array, 'ldapPort', $ldapconf->{'port'});
    push(@array, 'ldapBase' => $ldap->dn());
    push(@array, 'ldapRoot', $ldapconf->{'rootdn'});
    push(@array, 'ldapPasswd' => $ldap->getPassword());
    push(@array, 'usersDn' => $users->usersDn());

    push(@array, 'domain' => $settings->domainValue());
    push(@array, 'ssl' => $settings->sslValue());
    push(@array, 's2s' => $settings->s2sValue());

    push(@array, 'admins' => $jabberldap->getJabberAdmins());

    push(@array, 'muc' => $settings->mucValue());
    push(@array, 'stun' => $settings->stunValue());
    push(@array, 'proxy' => $settings->proxyValue());
    push(@array, 'zarafa' => $self->zarafaEnabled());
    push(@array, 'sharedroster' => $settings->sharedrosterValue());
    push(@array, 'vcard' => $settings->vcardValue());

    $self->writeConfFile(EJABBERDCONFFILE,
                 "jabber/ejabberd.cfg.mas",
                 \@array, { 'uid' => $jabuid, 'gid' => $jabgid, mode => '640' });
}

sub zarafaEnabled
{
    my ($self) = @_;

    my $gl = EBox::Global->getInstance();
    if ( $gl->modExists('zarafa') ) {
        my $zarafa = $gl->modInstance('zarafa');
        my $jabber = $zarafa->model('GeneralSettings')->jabberValue();
        return ($zarafa->isEnabled() and $jabber);
    }
    return 0;
}

# Method: menu
#
#       Overrides EBox::Module method.
sub menu
{
    my ($self, $root) = @_;
    $root->add(new EBox::Menu::Item('url' => 'Jabber/Composite/General',
                                    'text' => $self->printableName(),
                                    'separator' => 'Communications',
                                    'order' => 620));
}

# Method: _ldapModImplementation
#
#      All modules using any of the functions in LdapUserBase.pm
#      should override this method to return the implementation
#      of that interface.
#
# Returns:
#
#       An object implementing EBox::LdapUserBase
#
sub _ldapModImplementation
{
    return new EBox::JabberLdapUser();
}

# Method: certificates
#
#   This method is used to tell the CA module which certificates
#   and its properties we want to issue for this service module.
#
# Returns:
#
#   An array ref of hashes containing the following:
#
#       service - name of the service using the certificate
#       path    - full path to store this certificate
#       user    - user owner for this certificate file
#       group   - group owner for this certificate file
#       mode    - permission mode for this certificate file
#
sub certificates
{
    my ($self) = @_;

    return [
        {
             serviceId => 'Jabber Server',
             service =>  __('Jabber Server'),
             path    =>  '/etc/ejabberd/ejabberd.pem',
             user => 'root',
             group => 'ejabberd',
             mode => '0440',
        },
    ];
}

# Method: fqdn
#FIXME doc
sub fqdn
{
    my $fqdn = `hostname --fqdn`;
    if ($? != 0) {
        $fqdn = 'ebox.localdomain';
    }
    chomp $fqdn;
    return $fqdn;
}

sub fqdnChanged
{
    my ($self, $oldFqdn, $newFqdn) = @_;
    $self->_clearDatabase();
}

sub _clearDatabase
{
    my ($self) = @_;

    $self->setAsChanged(1);
    $self->stopService();

    killProcesses();
    sleep 3;
    killProcesses(1);

    EBox::Sudo::root('rm -rf ' . EJABBERD_DB_DIR);
}

sub killProcesses
{
    my ($force) = @_;
    my @kill;
    foreach my $process (qw(beam epms)) {
        `pgrep $process`;
        if ($? == 0) {
            push @kill, $process;
        }
    }
    @kill or return;

    if ($force) {
        system "killall -9 @kill";
    } else {
        system "killall  @kill";
    }
}


1;
