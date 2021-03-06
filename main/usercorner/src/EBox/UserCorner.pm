# Copyright (C) 2009-2012 eBox Technologies S.L.
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

package EBox::UserCorner;
use base qw(EBox::Module::Service);

use EBox::Config;
use EBox::Gettext;
use EBox::Global;
use EBox::Menu::Root;
use EBox::UserCorner;
use EBox::Util::Version;

use constant USERCORNER_USER  => 'ebox-usercorner';
use constant USERCORNER_GROUP => 'ebox-usercorner';
use constant USERCORNER_APACHE => EBox::Config->conf() . '/user-apache2.conf';
use constant USERCORNER_REDIS => '/var/lib/zentyal-usercorner/conf/redis.conf';
use constant USERCORNER_REDIS_PASS => '/var/lib/zentyal-usercorner/conf/redis.passwd';

sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'usercorner',
                                      printableName => __('User Corner'),
                                      @_);

    bless($self, $class);
    return $self;
}

# Method: usercornerdir
#
#      Get the path to the usercorner directory
#
# Returns:
#
#      String - the path to that directory
sub usercornerdir
{
    return EBox::Config->var() . 'lib/zentyal-usercorner/';
}

# Method: usersessiondir
#
#      Get the path where user Web session identifiers are stored
#
# Returns:
#
#      String - the path to that directory
sub usersessiondir
{
    return usercornerdir() . 'sids/';
}

# Method: journalDir
#
#      Get the path where operation files are stored for master/slave sync
#
# Returns:
#
#      String - the path to that directory
sub journalDir
{
 return EBox::UserCorner::usercornerdir() . 'syncjournal';
}

# Method: actions
#
#       Override EBox::Module::Service::actions
#
sub actions
{
    my ($self) = @_;

    my @actions;
    push (@actions,
            {
             'action' => __('Migrate configured modules'),
             'reason' => __('Required for usercorner access to configured modules'),
             'module' => 'usercorner'
            });

    push (@actions,
            {
             'action' => __('Create directories for slave journals'),
             'reason' => __('Zentyal needs the directories to record pending slave actions.'),
             'module' => 'usercorner'
            });

    return \@actions;
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
        my $fw = EBox::Global->modInstance('firewall');

        my $port = 8888;
        $fw->addInternalService(
                'name'            => 'usercorner',
                'printableName'   => __('User Corner'),
                'description'     => __('User Corner Web Server'),
                'protocol'        => 'tcp',
                'sourcePort'      => 'any',
                'destinationPort' => $port,
                );
        $fw->saveConfigRecursive();

        $self->setPort($port);
    }

    if (EBox::Util::Version::compare($version, '3.0.5') < 0) {
        my $journalDir = journalDir();
        my $oldJournalDir = EBox::UserCorner::usercornerdir() . 'userjournal';
        if ((-d $oldJournalDir) and not (-d $journalDir)) {
            # fix wrong path
            EBox::Sudo::root("mv '$oldJournalDir' '$journalDir'");
        }
    }

    # Execute initial-setup script
    $self->SUPER::initialSetup($version);
}

# Method: enableActions
#
#       Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    # Create userjournal dir if it not exists
    my @commands;
    my $ucUser = USERCORNER_USER;
    my $ucGroup = USERCORNER_GROUP;
    my $usercornerDir = EBox::UserCorner::journalDir();
    unless (-d $usercornerDir) {
        push (@commands, "mkdir -p $usercornerDir");
        push (@commands, "chown $ucUser:$ucGroup $usercornerDir");
        EBox::Sudo::root(@commands);
    }

    # migrate modules to usercorner
    (-d (EBox::Config::conf() . 'configured')) and return;

    my $names = EBox::Global->modNames();
    mkdir(EBox::Config::conf() . 'configured.tmp/');
    foreach my $name (@{$names}) {
        my $mod = EBox::Global->modInstance($name);
        my $class = 'EBox::Module::Service';
        if ($mod->isa($class) and $mod->configured()) {
            EBox::Sudo::command('touch ' . EBox::Config::conf() . 'configured.tmp/' . $mod->name());
        }
    }
    rename(EBox::Config::conf() . 'configured.tmp', EBox::Config::conf() . 'configured');
}

# Method: _daemons
#
#  Override <EBox::Module::Service::_daemons>
#
sub _daemons
{
    return [
        {
            'name' => 'ebox.apache2-usercorner'
        },
        {
            'name' => 'ebox.redis-usercorner'
        }
    ];
}

# Method: _setConf
#
#  Override <EBox::Module::Service::_setConf>
#
sub _setConf
{
    my ($self) = @_;

    # We can assume the listening port is ready available
    my $settings = $self->model('Settings');

    # Overwrite the listening port conf file
    EBox::Module::Base::writeConfFileNoCheck(USERCORNER_APACHE,
        "usercorner/user-apache2.conf.mas",
        [ port => $settings->portValue() ],
    );

    # Write user corner redis file
    $self->{redis}->writeConfigFile(USERCORNER_USER);

    # As $users->editableMode() can't be called from usercorner, it will check
    # for the existence of this file
    my $editableFile = '/var/lib/zentyal-usercorner/editable';
    if (EBox::Global->modInstance('users')->editableMode()) {
        EBox::Sudo::root("touch $editableFile");
    } else {
        EBox::Sudo::root("rm -f $editableFile");
    }
}

# Method: menu
#
#        Show the usercorner menu entry
#
# Overrides:
#
#        <EBox::Module::menu>
#
sub menu
{
    my ($self, $root) = @_;

    my $folder = new EBox::Menu::Folder('name' => 'UsersAndGroups',
                                        'text' => __('Users and Groups'),
                                        'separator' => 'Office',
                                        'order' => 510);

    my $item = new EBox::Menu::Item(text => $self->printableName(),
                                    url => 'UsersAndGroups/UserCorner',
                                    order => 100);
    $folder->add($item);
    $root->add($folder);
}

# Method: port
#
#       Returns the port the usercorner webserver is on
#
sub port
{
    my ($self) = @_;
    my $settings = $self->model('Settings');
    return $settings->portValue();
}

# Method: setPort
#
#       Sets the port the usercorner webserver is on
#
sub setPort
{
    my ($self, $port) = @_;

    my $settingsModel = $self->model('Settings');
    $settingsModel->set(port => $port);
}

sub certificates
{
    my ($self) = @_;

    return [
            {
             serviceId =>  q{User Corner web server},
             service =>  __(q{User Corner web server}),
             path    =>  '/var/lib/zentyal-usercorner/ssl/ssl.pem',
             user => USERCORNER_USER,
             group => USERCORNER_GROUP,
             mode => '0400',
            },
           ];
}

# Method: editableMode
#
#       Reimplementation of EBox::UsersAndGroups::editableMode()
#       compatible with user corner to workaround lack of redis access
#
#       Returns true if mode is editable
#
sub editableMode
{
    return (-f '/var/lib/zentyal-usercorner/editable');
}

1;
