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
use strict;
use warnings;

package EBox::CGI::Logs::Index;
use base 'EBox::CGI::ClientBase';

use EBox;
use EBox::Gettext;
use EBox::Global;
use EBox::Model::Manager;
use EBox::Validate;
use EBox::Html;
use POSIX qw(ceil);
use Error qw(:try);

use constant PAGESIZE => 15;

sub new # (error=?, msg=?, cgi=?)
{
    my $class = shift;
    my $self = $class->SUPER::new('title' => __('Logs'),
                                  'template' => '/logs/index.mas',
                                  @_);
    bless($self, $class);
    return $self;
}

sub _actualPage
{
    my ($self, $tpages) = @_;

    my $page = $self->param('page');

    unless (defined($self->param('page'))) {
        $page = 0;
    }

    if (defined($self->param('tofirst'))) {
        $page = 0;
    }
    if (defined($self->param('toprev'))) {
        if ($page > 0) {
            $page = $page -1;
        }
    }
    if (defined($self->param('tonext'))) {
        if ($page < $tpages) {
            $page = $page + 1;
        }
    }
    if (defined($self->param('tolast'))) {
        $page = $tpages;
    }

    return $page;
}


sub addToMasonParameters
{
    my ($self, @masonParams) = @_;


    defined $self->{params} or $self->{params} = [];
    my $oldParams_r= $self->{params};
    if (defined $oldParams_r) {
        push @masonParams, @{ $oldParams_r };
    }

    $self->{params}  = \@masonParams;
}


sub _fromDate
{
    my ($self) = @_;
    my $defaultPeriod = -24*3600; # one day
    my $fromDate = $self->_getDateArray('from', $defaultPeriod);

    return $fromDate;
}

sub _toDate
{
    my ($self) = @_;

    my $toDate;
    my $refresh = $self->refresh();

    if ($refresh) {
        # 86400 second -> one day
        $toDate = $self->_getDateArray('to', 86400, 0);
    }
    else {
        $toDate = $self->_getDateArray('to');
    }


    return $toDate;
}


sub _getDateArray
{
    my ($self, $prefix, $defaultTimeAdjust, $useParamsValue) = @_;
    defined $defaultTimeAdjust or $defaultTimeAdjust = 0;
    defined $useParamsValue    or $useParamsValue    = 1;

    my %time;

    my @localtime = localtime((time() + $defaultTimeAdjust));
    $time{$prefix . 'sec'}   = $localtime[0];
    $time{$prefix . 'min'}   = $localtime[1];
    $time{$prefix . 'hour'}  = $localtime[2];
    $time{$prefix . 'day'}   = $localtime[3];
    $time{$prefix . 'month'} = $localtime[4] + 1;
    $time{$prefix . 'year'}  = $localtime[5]  + 1900;


    if ($useParamsValue) {
        foreach my $key (keys %time) {
            my $paramValue = $self->param($key);
            if (defined $paramValue) {
                $time{$key} = $paramValue;
            }
        }

    }

    my @wantedOrder = map { $prefix . $_  }  qw(day month year hour min sec) ;
    my @dateArray = map {  $time{$_} }  @wantedOrder;

    return \@dateArray;
}


sub _searchLogs
{
    my ($self, $logs, $selected) = @_;

    my %hret;
    my $hfilters;
    my $tableinfo = $logs->getTableInfo($selected);
    my $table     = $tableinfo->{'tablename'};
    my $timecol   = 'timestamp';

    my $tpages = ceil($logs->totalRecords($table) / PAGESIZE) - 1;
    my $page = $self->_actualPage($tpages);

    my @fromdate = @{ $self->_fromDate() };
    my @todate   = @{ $self->_toDate() };

    try {
        $hfilters = $self->_paramFilters();
    } otherwise {
        my ($ex) = @_;
        $self->setErrorFromException($ex);
        $hfilters = {};
    };
    %hret = %{$logs->search($fromdate[2].'-'.$fromdate[1].'-'.$fromdate[0].' '.$fromdate[3].':'.$fromdate[4].':0',
                            $todate[2].'-'.$todate[1].'-'.$todate[0].' '.$todate[3].':'.$todate[4].':0',
                            $selected,
                            PAGESIZE,
                            $page,
                            $timecol,
                            $hfilters)};

    $tpages = ceil ($hret{'totalret'} / PAGESIZE) -1;
    $page = $self->_actualPage($tpages);

    my @masonParameters;
    push(@masonParameters, 'filters' => _encode_filters($hfilters));
    push(@masonParameters, 'tableinfo' => $tableinfo);

    push(@masonParameters, 'page' => $page);
    push(@masonParameters, 'tpages' => $tpages);
    push(@masonParameters, 'data' => $hret{'arrayret'});
    push(@masonParameters, 'fromdate' => \@fromdate);
    push(@masonParameters, 'todate' => \@todate);

    $self->addToMasonParameters(@masonParameters);

}

sub _encode_filters {
        my ($par) = @_;

        my %encoded = map { $par->{$_} =~ s/'/&#39;/g; $_ => $par->{$_}  }
                        keys %{$par};

        return \%encoded;
}

# Method called when the user may want to save the query as an event
# to be notified
sub _saveAsEvent
{
    my ($self) = @_;

    # Get filters
    my $hfilters = $self->_paramFilters();
    my $selected = $self->param('selected');

    # TODO Use new row/ids API
    my $manager = EBox::Model::Manager->instance();
    my $logConfModel = $manager->model('events/LogWatcherConfiguration');
    my $loggerConfRow = $logConfModel->findValue(domain => $selected);
    my $logFilteringDirectory = $loggerConfRow->{filters}->{directory};

    my $modelName = "LogWatcherFiltering_$selected";
    my $url = "Events/View/$modelName";
    my $params = "?action=presetUpdate&tablename=$modelName&directory=$logFilteringDirectory&page=0&filter=&pagesize=10";
    while (my ($key, $value) = each %{$hfilters}) {
        if ( $key eq 'event' and not $value) {
            $value = 'any';
        }
        # Do not pass the empty values ''
        next unless ( $value );
        $params .= "&$key=$value";
    }

    $self->setRedirect( $url . $params );
    return;

}

# Function to get the filters from CGI parameters
# Return an hash ref indexed by filter's name
sub _paramFilters
{
    my ($self) = @_;

    my $hfilters = {};
    foreach my $filter (grep(s/^filter-//, @{$self->params()})) {
        my $value = $self->unsafeParam("filter-$filter");
        if (defined $value and ($filter ne 'event')) {
            # no regex for 'event'
            EBox::Validate::checkRegex($value, $filter);
        }
        $hfilters->{$filter} = $value;
    }
    return $hfilters;

}


sub _header
{
    my ($self) = @_;

    if (not $self->refresh()) {
        $self->SUPER::_header();
        return;
    }


    my $destination = "/Logs/Index?";

    my %params = %{ $self->paramsAsHash() };
    $params{refresh} = 1; # to assure the refresh parameter is active

    while (my ($param, $value) = each %params) {
        if ($param eq 'View') {
            # View we want to only use it the first time to set default refresh
            # as 1
            next;
        }

        $destination .= "$param=$value&";
    }
    $destination =~ s/&$//;

    my $global = EBox::Global->getInstance();
    my $favicon = $global->theme()->{'favicon'};

    print($self->cgi()->header(-charset=>'utf-8'));
    my $html = EBox::Html::makeHtml(
                                     'headerWithRefresh.mas',
                                     title => $self->{title},
                                     destination => $destination,
                                     favicon => $favicon,
                                    );
    print $html;
}

sub refresh
{
    my ($self) = @_;

    return 1 if $self->param('refresh');
    return 1 if $self->param('View');

    return 0;
}

sub _process
{
    my ($self) = @_;

    my $logs = EBox::Global->modInstance('logs');

    # The user may click on saveAsEvent
    if ( $self->param('saveAsEvent') ) {
        $self->_saveAsEvent();
        return;
    }

    my $selected = $self->param('selected');

    if (defined($selected)) {
        $self->_searchLogs($logs, $selected);
    } else {
        $selected = 'none';
    }

    $self->{crumbs} = [
        {   title => __('Query Logs'),
            link => '/Maintenance/Logs'
        },
        {   title => __('Full Reports'),
            link => "/Logs/Index?selected=$selected&refresh=1"
        },
    ];

    my @masonParameters;
    push(@masonParameters, 'logdomains' => $logs->getLogDomains());
    push(@masonParameters, 'selected' => $selected);

    push(@masonParameters, refresh => $self->refresh);

    $self->addToMasonParameters(@masonParameters);
}

sub menuFolder
{
    return 'Maintenance';
}

# Overrides: EBox::CGI::Base::params
#
# We need to override this because the name of a parameter could be
# internaltionalized and thus contian unexpecteed characters
sub params
{
    my ($self) = @_;
    my $cgi = $self->cgi;
    my @names = $cgi->param;

    # Prototype adds a '_' empty param to Ajax POST requests when the agent is
    # webkit based
    @names = grep { !/^_$/ } @names;
    return \@names;
}

1;
