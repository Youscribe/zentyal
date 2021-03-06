# Copyright (C) 2008-2012 eBox Technologies S.L.
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

package EBox::CGI::CA::RenewCertificate;

use strict;
use warnings;

use base 'EBox::CGI::ClientBase';

use EBox::Gettext;
use EBox::Global;
# For exceptions
use Error qw(:try);
use EBox::Exceptions::DataInUse;

# Method: new
#
#       Constructor for RenewCertificate CGI
#
# Returns:
#
#       RenewCertificate - The object recently created

sub new
  {

    my $class = shift;

    my $self = $class->SUPER::new('title' => __('Certification Authority'),
				  @_);

    $self->{chain} = "CA/Index";
    bless($self, $class);

    return $self;

  }

# Process the HTTP query

sub _process
  {

    my $self = shift;

    my $ca = EBox::Global->modInstance('ca');

    if ( $self->param('cancel') ) {
      $self->setRedirect( 'CA/Index' );
      $self->setMsg( __("The certificate has NOT been renewed") );
      $self->cgi()->delete_all();
      return;
    }

    $self->_requireParam('isCACert', __('Boolean indicating Certification Authority Certificate') );
    $self->_requireParam('expireDays', __('Days to expire') );

    my $commonName = $self->unsafeParam('commonName');
    # We have to check it manually
    if ( not defined($commonName) or $commonName eq '' ) {
        throw EBox::Exceptions::DataMissing(data => __('Common Name'));
    }
    # Only valid chars minus '/' plus '*' --> security risk
    unless ( $commonName =~ m{^[\w .?&+:\-\@\*]*$} ) {
        throw EBox::Exceptions::External(__('The input contains invalid ' .
                                            'characters. All alphanumeric characters, ' .
					    'plus these non alphanumeric chars: .?&+:-@* ' .
					    'and spaces are allowed.'));
    }

    # Transform %40 in @
    $commonName =~ s/%40/@/g;
    # Transform %20 in space
    $commonName =~ s/%20/ /g;

    my $isCACert = $self->param('isCACert');
    my $expireDays = $self->param('expireDays');
    my $caPassphrase = $self->param('caPassphrase');
    $caPassphrase = undef if ( $caPassphrase eq '' );

    unless ( $expireDays > 0) {
        throw EBox::Exceptions::External(__x('Days to expire ({days}) must be '
                                             . 'a positive number',
                                             days => $expireDays));
    }

    my $retValue;
    my $retFromCatch;
    if ( defined ($self->param('renewForced')) ) {
	if ( $isCACert ) {
	  $retValue = $ca->renewCACertificate( days => $expireDays,
                                               caKeyPassword => $caPassphrase,
					       force => 'true',
					     );
	} else {
	  $retValue = $ca->renewCertificate( commonName => $commonName,
					     days       => $expireDays,
                                             caKeyPassword => $caPassphrase,
					     force      => 'true',
					   );
	}
    }
    else {
      try {
      if ( $isCACert ) {
	  $retValue = $ca->renewCACertificate( days => $expireDays,
                                               caKeyPassword => $caPassphrase,
                                               );
	} else {
	  $retValue = $ca->renewCertificate( commonName    => $commonName,
                                             caKeyPassword => $caPassphrase,
					     days          => $expireDays);
	}
      } catch EBox::Exceptions::DataInUse with {
	$self->{template} = '/ca/forceRenew.mas';
	$self->{chain} = undef;
	my $cert = $ca->getCertificateMetadata( cn => $commonName );
	my @array;
	push (@array, 'metaDataCert' => $cert);
	push (@array, 'expireDays'   => $expireDays);
        push (@array, 'caPassphrase' => $caPassphrase);
	$self->{params} = \@array;
	$retFromCatch = 1;
      };
    }

    if ( not $retFromCatch ) {
      if (not defined($retValue) ) {
	throw EBox::Exceptions::External(__('The certificate CANNOT be renewed'));
      } else {
	my $msg = __("The certificate has been renewed");
	$msg = __("The new CA certificate has been renewed") if ($isCACert);
	$self->setMsg($msg);
        $self->cgi()->delete_all();
      }
    }

  }

1;
