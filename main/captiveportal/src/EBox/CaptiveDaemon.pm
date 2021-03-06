# Copyright (C) 2011-2012 eBox Technologies S.L.
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

# Class: EBox::CaptiveDaemon
#
# This class is the daemon which is in charge of managing captive
# portal sessions. Iptables rules are added in order to let the users
# access the network.
#
# Already logged users rules are created at EBox::CaptivePortalFirewall so
# this daemons is only in charge of new logins and logouts / expired sessions
package EBox::CaptiveDaemon;

use EBox::Config;
use EBox::Global;
use EBox::CaptivePortal;
use EBox::Sudo;
use Error qw(:try);
use EBox::Exceptions::DataExists;
use EBox::Util::Lock;
use Linux::Inotify2;
use EBox::Gettext;
use Time::HiRes qw(usleep);

# iptables command
use constant IPTABLES => '/sbin/iptables';

sub new
{
    my ($class) = @_;
    my $self = {};

    # Sessions already added to iptables (to trac ip changes)
    $self->{sessions} = {};
    $self->{module} = EBox::Global->modInstance('captiveportal');

    # Use bwmonitor if it exists
    if (EBox::Global->modExists('bwmonitor')) {
        $self->{bwmonitor} = EBox::Global->modInstance('bwmonitor');
    }

    $self->{pendingRules} = undef;

    bless ($self, $class);
    return $self;
}

# Method: run
#
#   Run the daemon. It never dies
#
sub run
{
    my ($self) = @_;

    # Setup iNotify to detect logins
    my $notifier = Linux::Inotify2->new();
    unless (defined($notifier)) {
        throw EBox::Exceptions::External('Unable to create inotify listener');
    }

    $notifier->blocking (0); # set non-block mode

    # Create logout file
    EBox::Sudo::root('touch ' . EBox::CaptivePortal->LOGOUT_FILE);

    # wakeup on new session and logout events
    $notifier->watch(EBox::CaptivePortal->SIDS_DIR, IN_CREATE, sub {});
    $notifier->watch(EBox::CaptivePortal->LOGOUT_FILE, IN_CLOSE, sub {});

    my $global = EBox::Global->getInstance(1);
    my $captive = $global->modInstance('captiveportal');
    my $expirationTime = $captive->expirationTime();

    my $exceededEvent = 0;
    my $events = $global->getInstance(1)->modInstance('events');
    try {
        if ((defined $events)  and ($events->isRunning())) {
            $exceededEvent =
                $events->isEnabledWatcher('EBox::Event::Watcher::CaptivePortalQuota');
        }
    } otherwise {
        $exceededEvent = 0;
    };

    my $timeLeft;
    while (1) {
        my @users = @{$self->{module}->currentUsers()};
        $self->_updateSessions(\@users, $events, $exceededEvent);

        my $endTime = time() + $expirationTime;
        while (time() < $endTime) {
            my $eventsFound = $notifier->poll();
            if ($eventsFound) {
                last;
            }
            usleep(80);
        }
    }
}

# Method: _updateSessions
#
#   Init/finish user sessions and manage
#   firewall rules for them
#
sub _updateSessions
{
    my ($self, $currentUsers, $events, $exceededEvent) = @_;
    my @rules;
    my @removeRules;

    # firewall already inserted rules, checked to avoid duplicates
    my $iptablesRules = {
        captive  => join('', @{EBox::Sudo::root(IPTABLES . ' -t nat -n -L captive')}),
        icaptive => join('', @{EBox::Sudo::root(IPTABLES . ' -n -L icaptive')}),
        fcaptive => join('', @{EBox::Sudo::root(IPTABLES . ' -n -L fcaptive')}),
    };

    foreach my $user (@{$currentUsers}) {
        my $sid = $user->{sid};
        my $new = 0;

        # New sessions
        if (not exists($self->{sessions}->{$sid})) {
            $self->{sessions}->{$sid} = $user;
            push (@rules, @{$self->_addRule($user, $iptablesRules)});

            # bwmonitor...
            $self->_matchUser($user);

            $new = 1;
            if ($exceededEvent) {
                    $events->sendEvent(
                        message => __x('{user} has logged in captive portal and has quota left',
                                       user => $user->{'user'},
                                      ),
                        source  => 'captiveportal-quota',
                        level   => 'info',
                        dispatchTo => [ 'ControlCenter' ],
                        additional => {
                            outOfQuota => 0,
                            %{ $user }, # all fields from CaptivePortal::Model::Users::currentUsers
                           }
                       );
                }
        }

        # Check for expiration or quota exceeded
        my $quotaExceeded = $self->{module}->quotaExceeded($user->{user}, $user->{bwusage}, $user->{quotaExtension});
        if ($quotaExceeded or $self->{module}->sessionExpired($user->{time})  ) {
            $self->{module}->removeSession($user->{sid});
            delete $self->{sessions}->{$sid};
            push (@removeRules, @{$self->_removeRule($user)});

            # bwmonitor...
            $self->_unmatchUser($user);

            if ($quotaExceeded) {
                if ($exceededEvent) {
                    $events->sendEvent(
                        message => __x('{user} is out of quota in captive portal with a usage of {bwusage} Mb',
                                       user => $user->{'user'},
                                       bwusage => $user->{'bwusage'}
                                      ),
                        source  => 'captiveportal-quota',
                        level   => 'warn',
                        additional => {
                             outOfQuota => 1,
                            %{ $user }, # all fields from CaptivePortal::Model::Users::currentUsers
                        }
                       );
                }
            }

            next;
        }

        # Check for IP change
        unless ($new) {
            my $oldip = $self->{sessions}->{$sid}->{ip};
            my $newip = $user->{ip};
            unless ($oldip eq $newip) {
                # Ip changed, update rules
                push (@rules, @{$self->_addRule($user)});
                push (@rules, @{$self->_removeRule($self->{sessions}->{$sid})});

                # bwmonitor...
                $self->_matchUser($user);
                $self->_unmatchUser($self->{sessions}->{$sid});

                # update ip
                $self->{sessions}->{$sid}->{ip} = $newip;
            }
        }
    }

    if (@rules or @removeRules or $self->{pendingRules}) {
        # try to get firewall lock
        my $lockedFw = 0;
        try {
            EBox::Util::Lock::lock('firewall');
            $lockedFw = 1;
        } otherwise {};

        if ($lockedFw) {
            try {
                my @pending;
                if ($self->{pendingRules}) {
                    @pending = @{ $self->{pendingRules} };
                    $self->{pendingRules} = undef;
                }
                EBox::Sudo::root(@pending, @rules, @removeRules) ;
            } finally {
                EBox::Util::Lock::unlock('firewall');
            };
        } else {
            $self->{pendingRules} or $self->{pendingRules} = [];
            push @{ $self->{pendingRules} }, @rules, @removeRules;
            EBox::error("Captive portal cannot lock firewall, we will try to add pending firewall rules later. Users access could be inconsistent until rules are added");
        }
    }
}

sub _addRule
{
    my ($self, $user, $current) = @_;

    my $ip = $user->{ip};
    my $name = $user->{user};
    EBox::debug("Adding user $name with IP $ip");

    my $rule = $self->{module}->userFirewallRule($user);
    my @rules;
    push (@rules, IPTABLES . " -t nat -I captive $rule") unless($current->{captive} =~ / $ip /);
    push (@rules, IPTABLES . " -I fcaptive $rule") unless($current->{fcaptive} =~ / $ip /);
    push (@rules, IPTABLES . " -I icaptive $rule") unless($current->{icaptive} =~ / $ip /);
    # conntrack remove redirect conntrack (this will remove
    # conntrack state for other connections from the same source but it is not
    # important)
    push (@rules, "conntrack -D -p tcp --src $ip");

    return \@rules;
}

sub _removeRule
{
    my ($self, $user) = @_;

    my $ip = $user->{ip};
    my $name = $user->{user};
    EBox::debug("Removing user $name with IP $ip");

    my $rule = $self->{module}->userFirewallRule($user);
    my @rules;
    push (@rules, IPTABLES . " -t nat -D captive $rule");
    push (@rules, IPTABLES . " -D fcaptive $rule");
    push (@rules, IPTABLES . " -D icaptive $rule");
    # remove conntrack (this will remove conntack state for other connections
    # from the same source but it is not important)
    push (@rules, "conntrack -D --src $ip");

    return \@rules;
}


# Match the user in bwmonitor module
sub _matchUser
{
    my ($self, $user) = @_;

    if ($self->{bwmonitor} and $self->{bwmonitor}->isEnabled()) {
        try {
            $self->{bwmonitor}->addUserIP($user->{user}, $user->{ip});
        } catch EBox::Exceptions::DataExists with {}; # already in
    }
}

# Unmatch the user in bwmonitor module
sub _unmatchUser
{
    my ($self, $user) = @_;

    if ($self->{bwmonitor} and $self->{bwmonitor}->isEnabled()) {
        $self->{bwmonitor}->removeUserIP($user->{user}, $user->{ip});
    }
}

###############
# Main program
###############

EBox::init();

EBox::info('Starting Captive Portal Daemon');
my $captived = new EBox::CaptiveDaemon();
$captived->run();


