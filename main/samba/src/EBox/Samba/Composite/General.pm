# Copyright (C) 2012 eBox Technologies S.L.
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

package EBox::Samba::Composite::General;

use base 'EBox::Model::Composite';

use strict;
use warnings;

use EBox::Gettext;

# Group: Public methods

# Constructor: new
#
#         Constructor for the general events composite
#
# Returns:
#
#       <EBox::Samba::Model::General> - a
#       general events composite
#
sub new
{

    my ($class, @params) = @_;

    my $self = $class->SUPER::new(@params);

    return $self;

}

# Method: _description
#
# Overrides:
#
#     <EBox::Model::Composite::_description>
#
sub _description
{
    my $description = {
       layout          => 'tabbed',
       name            =>  __PACKAGE__->nameFromClass,
       pageTitle       => __('File Sharing'),
       printableName   => __('File sharing options'),
       compositeDomain => 'Samba',
       #help            => __(''), # TODO
    };

    return $description;
}

# Method: componentNames
#
# Overrides:
#
#     <EBox::Model::Composite::componentNames>
#
sub componentNames
{
    my ($self) = @_;

    my @components = qw(GeneralSettings SambaShares RecycleBin Antivirus);

    if (EBox::Global->modExists('remoteservices')) {
        my $rs = EBox::Global->modInstance('remoteservices');
        if ($rs->filesSyncAvailable()) {
            push (@components, 'SyncShares');
        }
    }

    return \@components;
}

1;
