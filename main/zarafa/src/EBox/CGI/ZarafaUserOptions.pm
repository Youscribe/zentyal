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

package EBox::CGI::Zarafa::ZarafaUserOptions;
use base 'EBox::CGI::ClientBase';

use EBox::Global;
use EBox::Gettext;
use EBox::ZarafaLdapUser;

## arguments:
##      title [required]
sub new
{
    my $class = shift;
    my $self = $class->SUPER::new('title' => 'Zarafa',
                                  @_);

    bless($self, $class);
    return $self;
}

sub _process
{
    my ($self) = @_;

    my $zarafaldap = new EBox::ZarafaLdapUser;

    $self->_requireParam('user', __('user'));
    my $user = $self->unsafeParam('user');
    $self->{redirect} = "UsersAndGroups/User?user=$user";

    $self->keepParam('user');

    $user = new EBox::UsersAndGroups::User(dn => $user);

    if ($self->param('active') eq 'yes') {
        if ($zarafaldap->hasAccount($user)) {
            if (defined($self->param('has_pop3'))) {
                $zarafaldap->setHasFeature($user, 'pop3', 1);
            } else {
                $zarafaldap->setHasFeature($user, 'pop3', 0);
            }
            if (defined($self->param('has_imap'))) {
                $zarafaldap->setHasFeature($user, 'imap', 1);
            } else {
                $zarafaldap->setHasFeature($user, 'imap', 0);
            }
            if (defined($self->param('is_admin'))) {
                $zarafaldap->setIsAdmin($user, 1);
            } else {
                $zarafaldap->setIsAdmin($user, 0);
            }
            if (defined($self->param('meeting_autoaccept'))) {
                $zarafaldap->setMeetingAutoaccept($user, 1);
            } else {
                $zarafaldap->setMeetingAutoaccept($user, 0);
            }
            if (defined($self->param('meeting_declineconflict'))) {
                $zarafaldap->setMeetingDeclineConflict($user, 1);
            } else {
                $zarafaldap->setMeetingDeclineConflict($user, 0);
            }
            if (defined($self->param('meeting_declinerecurring'))) {
                $zarafaldap->setMeetingDeclineRecurring($user, 1);
            } else {
                $zarafaldap->setMeetingDeclineRecurring($user, 0);
            }
        } else {
            $zarafaldap->setHasAccount($user, 1);
        }
    } else {
        if ($zarafaldap->hasAccount($user)) {
            $zarafaldap->setHasAccount($user, 0);
        } else {
            if (defined($self->param('contact'))) {
                $zarafaldap->setHasContact($user, 1);
            } else {
                $zarafaldap->setHasContact($user, 0);
            }
        }
    }
}

1;
