package CpanelReplication;
################################################################################
# Provides hooks to replicate WHM/cPanel API functions between nodes.
# Author: Trevor Kulhanek (2019)
################################################################################
use warnings; use strict;

use HTTP::Tiny ();
use HTTP::CookieJar;
use JSON;

# Read config files
open(my $fh, '<', '/etc/cprepl.d/remote_hosts') or die $!;
my $host = <$fh>;
close $fh;

open($fh, '<', '/etc/cprepl.d/authkeys') or die $!;
my $token = <$fh>;
chomp $token;
close $fh;

my @events = ();
open($fh, '<', '/etc/cprepl.d/events') or die $!;
while(<$fh>) {
    chomp;
    next if /^(\s*(#.*)?)?$/; # ignore blank lines / comments
    push @events, $_;
}
close $fh;

my $ua = HTTP::Tiny->new(
    'verify_SSL'      => 0,
    'default_headers' => {'Authorization' => "whm root:$token"},
);

# Whostmgr event-method hash
my %whmfunctions = (
    'Accounts::Modify' => 'modifyacct',
    'Accounts::suspendacct' => 'suspendacct',
    'Accounts::unsuspendacct' => 'unsuspendacct',
    'AutoSSL::installssl' => 'installssl',
    'SSL::installssl' => 'installssl',
    'Lang::PHP::ini_set_content' => 'php_ini_set_content',
    'Lang::PHP::ini_set_directives' => 'php_ini_set_directives',
    'Lang::PHP::set_handler' => 'php_set_handler',
    'Lang::PHP::set_system_default_version' => 'php_set_system_default_version',
    'Lang::PHP::set_vhost_versions' => 'php_set_vhost_versions',
);

# hook attributes
sub describe {
    my $hooks = [];
    foreach my $ev (@events) {
        my ($category, $event) = split /\//, $ev;
        if ($category eq "Whostmgr") {
            if ($event eq "Domain::park") {
                push @$hooks, {'category'=>$category,'event'=>$event,'stage'=>'post','hook'=>"CpanelReplication::park_domain",'exectype' => 'module'};
            } elsif ($event eq "Domain::unpark") {
                push @$hooks, {'category'=>$category,'event'=>$event,'stage'=>'post','hook'=>"CpanelReplication::unpark_domain",'exectype' => 'module'};
            } else {
                push @$hooks, {'category'=>$category,'event'=>$event,'stage'=>'post','hook'=>"CpanelReplication::whostmgr_rexec",'exectype' => 'module'};
            }
        } elsif ($category eq "Cpanel") {
            my ($api) = $event =~ /([^:]+)::/;
            if ($api eq 'UAPI') {
                push @$hooks, {'category'=>$category,'event'=>$event,'stage'=>'post','hook'=>'CpanelReplication::uapi_rexec','exectype' => 'module'};
            } elsif ($api eq 'Api2') {
                push @$hooks, {'category'=>$category,'event'=>$event,'stage'=>'post','hook'=>'CpanelReplication::api2_rexec','exectype' => 'module'};
            }
        } elsif ($category eq 'Passwd') {
            push @$hooks, {'category'=>$category,'event'=>$event,'stage'=>'post','hook'=>"CpanelReplication::passwd",'exectype' => 'module'};
        }
    }
    return $hooks;
}

################################################################################
# create_cpanel_session()
#
# @param    $cpuser - username of cPanel user to create session for.
# @return   string containing authenticated login URL for user.
#
################################################################################
sub create_cpanel_session {
    my ($cpuser) = @_;
    my $res = $ua->get("https://$host:2087/json-api/create_user_session?api.version=1&user=$cpuser&service=cpaneld");
    my $decoded_payload = decode_json($res->{content});
    my $session_url = $decoded_payload->{'data'}->{'url'};
    # Replace hostname with IP
    $session_url =~ s/.+(?=cpsess)//;
    $session_url = "https://" . $host . ":2083/" . $session_url;
    return $session_url;
}

################################################################################
# create_cpanel_client()
#
# @param    $loginurl - login URL of authenticated session.
# @return   New HTTP::Tiny instance containing authenticated cPanel session.
#
################################################################################
sub create_cpanel_client {
    my ($loginurl) = @_;
    my $ua = HTTP::Tiny->new(
        'verify_SSL' => 0,
        'cookie_jar' => HTTP::CookieJar->new,
    );
    $ua->get($loginurl);
    return $ua
}

################################################################################
# getmaindomain()
#
# @param    $cpuser - username of cPanel user to retrieve main domain for.
# @return   string containing user's main domain.
#
################################################################################
sub getmaindomain {
    my ($cpuser) = @_;
    my $match = "";
    open(my $fh, '<', '/etc/userdatadomains') or die $!;
    while (my $line = <$fh>) {
        my ($tmp,$user,$owner,$type, $domain) = split /==|: /, $line;
        if ($type eq "main" && $user eq $cpuser) {
            $match = $domain;
            last;
        }
    }
    close $fh;
    return $match;
}

### UAPI
sub uapi_rexec {
    my ($context, $data) = @_;
    my @fields = split /::/, $context->{'event'};
    my $method = "$fields[1]/$fields[2]";
    my $session_url = create_cpanel_session($data->{'user'});
    my $user_ua = create_cpanel_client($session_url);
    $session_url =~ s{/login(?:/)??.*}{};
    my $response = $user_ua->post_form("$session_url/execute/$method", $data->{'args'});
}

### whmapi1
sub whostmgr_rexec {
    my ($context, $data) = @_;
    my $method = $whmfunctions{$context->{'event'}};
    my $response = $ua->post_form("https://$host:2087/json-api/$method?api.version=1", $data);
}

### cPanel API2
sub api2_rexec {
    my ($context, $data) = @_;
    my ($api, $module, $function) = split /::/, $context->{'event'};
    my $cpuser = $data->{'user'};
    my $response = $ua->post_form("https://$host:2087/json-api/cpanel?cpanel_jsonapi_user=$cpuser&cpanel_jsonapi_apiversion=2&cpanel_jsonapi_module=$module&cpanel_jsonapi_func=$function", $data->{'args'});
}

# Whostmgr/Domain::park
sub park_domain {
    my ($context, $data) = @_;
    my ($api, $module, $function) = split /::/, $context->{'event'};
    my $domain = $data->{'target_domain'};
    my $body = {
        'cpanel_jsonapi_user'       => $data->{'user'},
        'cpanel_jsonapi_apiversion' => '2',
        'cpanel_jsonapi_module'     => 'Park',
        'cpanel_jsonapi_func'       => 'park',
        'domain'                    => $data->{'new_domain'},
    };
    # Get primary domain
    my $rootdomain = getmaindomain($data->{'user'});
    $domain =~ s/$rootdomain//;
    if (length($domain) > 0) {
        push @$body, {'topdomain' => $domain};
    }
    my $response = $ua->post_form("https://$host:2087/json-api/cpanel", $body);
}

# Whostmgr/Domain::unpark
sub unpark_domain {
    my ($context, $data) = @_;
    my ($api, $module, $function) = split /::/, $context->{'event'};
    my $body = {
        'cpanel_jsonapi_user'       => $data->{'user'},
        'cpanel_jsonapi_apiversion' => '2',
        'cpanel_jsonapi_module'     => 'Park',
        'cpanel_jsonapi_func'       => 'unpark',
        'domain'                    => $data->{'domain'}
    };
    my $response = $ua->post_form("https://$host:2087/json-api/cpanel", $body);
}

# Passwd/ChangePasswd
sub passwd {
    my ($context, $data) = @_;
    my $body = {
        'user'           => $data->{'user'},
        'password'       => $data->{'new_password'},
        'db_pass_update' => $data->{'optional_services'}->{'mysql'},
    };
    my $response = $ua->post_form("https://$host:2087/json-api/passwd?api.version=1", $body);
}