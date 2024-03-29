#!/usr/bin/perl -w
#
# gmail-labeler: A tool used to set a Gmail message's labels
#
# thomaschan@gmail.com
#
$| = 1;

use strict;
use Data::Dumper;
use Google::API::Client;
use Google::API::OAuth2::Client;
use Config::Simple;
use Storable qw(freeze thaw store retrieve);
use Crypt::CBC;
use IO::Prompter;
use Getopt::Long;
use File::Basename;
use Crypt::OpenSSL::AES;

my $homedir = $ENV{HOME};

sub usage {
   my $message = $_[0];
   if (defined $message && length $message) {
      $message .= "\n"
         unless $message =~ /\n$/;
   }
   my $command = $0;
   $command =~ s#^.*/##;
   print STDERR (
      $message,
      "Usage: $command -i ID -a \"LABELS\" -r \"LABELS\" [-d] [-l] [-f .gmail-labelerrc] [-p PW]\n" .
      "  -i ID      Message ID to label\n" .
      "  -l         List labels only\n" .
      "  -a LABELS  Add labels in CSV format (comma-separated)\n" .
      "  -r LABELS  Remove labels in CSV format (comma-separated)\n" .
      "  -f         Path to a .gmail-labelerrc file\n" .
      "  -d         Dry run, just print out what we plan on doing\n" .
      "  -p PW      Provide password to token on the command line.  Not safe!\n" 
   );
   die("\n")
}

my $opt_labels = "";
my $opt_add = "";
my $opt_remove = "";
my $opt_help;
my $opt_gmaillabelerrc;
my $opt_messageid = "";
my $opt_dryrun = "";
my $opt_passwd = "";
Getopt::Long::GetOptions(
    'l' => \$opt_labels,
    'a=s' => \$opt_add,
    'r=s' => \$opt_remove,
    'f=s' => \$opt_gmaillabelerrc,
    'i=s' => \$opt_messageid,
    'd' => \$opt_dryrun,
    'p=s' => \$opt_passwd,
    'h|help' => \$opt_help,
)
or usage("Invalid commmand line options.");
if ($opt_help) {
    usage("");
}

# Default variables
my $defaultconfig = $ENV{"HOME"} . "/.gmail-labelerrc";
my $clientid = "";
my $clientsecret = "";
my $tokenfile = $ENV{"HOME"} . ".gmail-labeler/token.dat";
my $passwd = "";
my $logfile = $ENV{"HOME"} . ".gmail-labeler/.gmail-labeler.log";
my $failfile = $ENV{"HOME"} . ".gmail-labeler/failure.log";
my $debug = 0;

# Read from config file
my $configfile = $opt_gmaillabelerrc || $defaultconfig;
if ( -e $configfile ) {
    readconfig($configfile);
}
else {
    print "WARNING: $configfile does not exist, creating from template.\n";
    print "         Please edit and run again.\n";
    writeconfig($configfile);
    exit;
}

sub readconfig {
    my ($configfile) = @_;
    my $config = new Config::Simple($configfile);
    $clientid = $config->param('clientid') || $clientid;
    $clientsecret = $config->param('clientsecret') || $clientsecret;
    $tokenfile = $config->param('token') || $tokenfile;
    $tokenfile =~ s/~/$homedir/g;
    $passwd = $config->param('passwd') || $passwd;
    $logfile = $config->param('logfile') || $logfile;
    $logfile =~ s/~/$homedir/g;
    $failfile = $config->param('failfile') || $failfile;
    $failfile =~ s/~/$homedir/g;
    $debug = $config->param('debug') || $debug;
}

if (!$opt_labels) {
    if ($opt_messageid =~ /^([a-zA-Z0-9]+)$/) {
        $opt_messageid = $1;
    }
    else {
        usage("Invalid message id.");
    }
    if ($opt_add) {
        if ($opt_add=~ /^([a-zA-Z0-9._, \/-]+)$/) {
            $opt_add = $1;
        }
        else {
            usage("Invalid labels.");
        }
    }
    if ($opt_remove) {
        if ($opt_remove=~ /^([a-zA-Z0-9._, \/-]+)$/) {
            $opt_remove = $1;
        }
        else {
            usage("Invalid labels.");
        }
    }
    if ($opt_add || $opt_remove) {
        # We need either to proceed
    }
    else {
        usage("Need to specify labels to add/remove.");
    }
}

# Log our args before we initiate a google connection (just in case that fails)
$logfile && logit($logfile,"ID:$opt_messageid ADD:$opt_add REMOVE:$opt_remove");

# Initialize connection
my $client = Google::API::Client->new;
my $service = $client->build('gmail', 'v1');

# $service->{auth_doc} will provide all (overreaching) scopes
# We will instead just request the scopes we need.
#my $auth_doc = $service->{auth_doc};
my $auth_doc = {
    oauth2 => {
        scopes => {
            'https://www.googleapis.com/auth/gmail.labels' => 1,
            'https://www.googleapis.com/auth/gmail.modify' => 1,
        }
    }
};

# Set up client secrets
my $local_port = "8123";
my $auth_driver = Google::API::OAuth2::Client->new(
    {
        auth_uri => 'https://accounts.google.com/o/oauth2/auth',
        token_uri => 'https://accounts.google.com/o/oauth2/token',
        client_id => $clientid,
        client_secret => $clientsecret,
        redirect_uri => "http://127.0.0.1:$local_port",
        auth_doc => $auth_doc,
    }
);

# Set up token
my $encryptedtoken;
# Read in existing encrypted token
if ( -e $tokenfile ) {
    open (FH, $tokenfile);
    while (<FH>) {
        $encryptedtoken= $_;
    }
}
if ($encryptedtoken) {
    # Restore the previous token
    if ($opt_passwd) {
        &restoretoken($opt_passwd);
    }
    elsif ($passwd) {
        &restoretoken($passwd);
    }
    else {
        &restoretoken;
    }
}
else {
    # Get a new token
    &gettoken;
}

my $res;

my %labels;
labelmapping();

if ($opt_labels) {
    print "Current Gmail Labels\n";
    print "====================\n";
    foreach my $label (sort {lc($a) cmp lc($b)} keys %labels) {
        print "\'$label\'\n";
    }
    exit;
}

my @labelsadd = ();
foreach my $label (split /,/, $opt_add) {
    if (! $labels{$label}) {
        if ($opt_dryrun) {
            print "DRYRUN: Creating label \"$label\"\n";
            $logfile && logit($logfile,"DRYRUN: Creating label \"$label\"");
        }
        else {
            $debug && print "Creating label \"$label\"\n";
            $logfile && logit($logfile,"Creating label \"$label\"");
            createlabel($label);
        }
        labelmapping();
    }
    push @labelsadd, $labels{$label};

}
my @labelsremove = ();;
foreach my $label (split /,/, $opt_remove) {
    if (! $labels{$label}) {
        if ($opt_dryrun) {
            print "DRYRUN: Creating label \"$label\"\n";
            $logfile && logit($logfile,"DRYRUN: Creating label \"$label\"");
        }
        else {    
            $debug && print "Creating label \"$label\"\n";
            $logfile && logit($logfile,"Creating label \"$label\"");
            createlabel($label);
        }
        
        labelmapping();
    }
    push @labelsremove, $labels{$label};
}

if ($opt_dryrun) {
    print "DRYRUN: Labeling message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
    $logfile && logit($logfile,"DRYRUN: Labeling message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
}
else {
    $debug && print "Labeling message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
    $logfile && logit($logfile,"Labeling message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
    labelmessage($opt_messageid);
}

exit;

sub labelmapping {
    # Get labels name->id mapping

    $res = $service->users->labels->list(
        body => {
            userId => 'me',
        }
    )->execute({ auth_driver => $auth_driver });
    foreach my $label (@{$res->{labels}}) {
        my $label_id = $label->{id};
        my $label_name = $label->{name};
        $labels{$label_name} = $label_id;
    }
}

sub createlabel {
    my ($name) = @_;
    my %body;
    $body{body}{userId} = 'me';
    $body{body}{labelListVisibility} = 'labelShow';
    $body{body}{messageListVisibility} = 'show';
    $body{body}{name} = $name;
    eval {
        $res = $service->users->labels->create (
            %body
        )->execute({ auth_driver => $auth_driver });
    };
    if ($@ =~ /^404/) {
        $debug && print "Unable to create label $name\n";
        $logfile && logit($logfile,"Unable to create label $name");
        exit 1;
    }
    elsif ($@ =~ /^(.*?) at /) {
        $debug && print "$1: \"$name\"\n";
        $logfile && logit($logfile,"$1: \"$name\"");
        exit 1;       
    }
}

sub labelmessage {
    my ($opt_messageid) = @_;

    my %body;
    $body{body}{userId} = 'me';
    $body{body}{id} = $opt_messageid;
    $body{body}{addLabelIds} = \@labelsadd;
    $body{body}{removeLabelIds} = \@labelsremove;

    eval {
        $res = $service->users->messages->modify (
            %body
        )->execute({ auth_driver => $auth_driver });
    };
    if ($@ =~ /^404/) {
        $debug && print "ERROR: Unable to label message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
        $logfile && logit($logfile,"ERROR: Unable to label message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
        $failfile && logfail($logfile,"$opt_messageid \"$opt_add\" \"$opt_remove\""); 
    }
    elsif ($@ =~ /^500 .*(Can't connect.*?) at /) {
        $debug && print "ERROR: " . $1 . " for message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
        $logfile && logit($logfile,"ERROR: $1 for message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
        $failfile && logfail($logfile,"$opt_messageid \"$opt_add\" \"$opt_remove\""); 
    }
    elsif ($@ =~ /^400 .*(Invalid label.*?) at /) {
        $debug && print "ERROR: " . $1 . " for message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
        $logfile && logit($logfile,"ERROR: $1 for message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
        $failfile && logfail($logfile,"$opt_messageid \"$opt_add\" \"$opt_remove\""); 
    }
    elsif ($@ =~ /^(.*?) at /) {
        $debug && print "ERROR: " . $1 . " for message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
        $logfile && logit($logfile,"ERROR: $1 for message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
        $failfile && logfail($logfile,"$opt_messageid \"$opt_add\" \"$opt_remove\""); 
    }
    else {
        $debug && print "Labeled message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove\n";
        $logfile && logit($logfile,"Labeled message $opt_messageid with ADD:$opt_add, REMOVE:$opt_remove");
    }
}

# Encrypt string
sub encrypt {
    my ($payload,$key) = @_;
    my $cipher = Crypt::CBC->new(
        -key       => $key,
        -keylength => '256',
        -cipher    => "Crypt::OpenSSL::AES"
    );
    my $encrypted = $cipher->encrypt_hex($payload);
    return $encrypted;
}

# Decrypt string
sub decrypt {
    my ($payload,$key) = @_;
    my $cipher = Crypt::CBC->new(
        -key       => $key,
        -keylength => '256',
        -cipher    => "Crypt::OpenSSL::AES"
    );
    my $decrypted = $cipher->decrypt_hex($payload);
    return $decrypted;
}

# Restore token from encrypted string
sub restoretoken {
    my ($passphrase) = @_;
    if (! $passphrase) {
        $passphrase = prompt("Enter passphrase for existing token: ", -echo=>'*');
    }
    my $decrypted = decrypt($encryptedtoken,$passphrase) || "";
    if ($decrypted =~ /access_token/) {
        my $token = thaw($decrypted);
        $auth_driver->token_obj($token);
    }
    else {
        my $x = prompt("ERROR:\tUnable to decrypt token with passphrase.\n\tHit ENTER to get a new token or Ctrl-c to exit.\n\n");
        &gettoken;
    }
}

# Get new token and encrypt it
sub gettoken {
    my $url = $auth_driver->authorize_uri;

    print "Go to the following URL to authorize use:\n\n";
    print "  " . $url . "\n\n";

    my $code;

    print "Spinning up http://127.0.0.1:$local_port in 15 seconds.\n";
    if (my $output = prompt("Hit ENTER if you would rather authenticate manually: ", -yes, -single, -default=>'y', -timeout=>15) && !$_->timedout) {
        # We'll just parse the code out of the URL
        print "\n";
        my $returned_url = prompt("Paste the redirected URL from google after authenticating: ",-echo=>'*');
        print "\n";
        
        if ($returned_url =~ /[?&]code=([a-zA-Z0-9\/_-]+)&?/) {
            $code = $1;
        }
        else {
            print "ERROR: Couldn't parse URL\n";
            exit;
        }

    }
    else {
        # Spin up web server to accept redirect
        print "\n\n";
        print "Starting server at http://127.0.0.1:$local_port\n\n";
        print "Waiting for connection...\n\n";
    
        use HTTP::Daemon;
        use HTTP::Response;
 
        my $d = HTTP::Daemon->new(LocalPort => $local_port, ReuseAddr => 1) || die;
        HTTPD: while (my $c = $d->accept) {
            while (my $r = $c->get_request) {
                #print $r->uri->path . "\n";

                my $uri = $r->uri;
                my $query = $uri->query || "";
                #print "$query\n";

                if ($query =~ /code=([a-zA-Z0-9\/_-]+)&?/) {
                    $code = $1;
            
                    my $response = HTTP::Response->new('200');
                    $response->content('Received token, you may close this page');
                    $c->send_response($response);
                    last HTTPD;
                }
                else {
                    my $response = HTTP::Response->new('400');
                    $response->content('Invalid token URL');
                    $c->send_response($response);
                }
            }
            $c->close;
            undef($c);
        }
        $d->close;
        undef($d);
    }


    my $token = $auth_driver->exchange($code);
    if (! $token) {
        print "Token exchange rejected, try again.\n";
        exit;
    }

    my $passphrase = 1;
    my $passphrase2 = 2;
    until ($passphrase eq $passphrase2) {
        print "\n";
        print "We will now encrypt your code before caching it.\n";
        print "Leave the passphrase blank if you don't want to cache it.\n";
        print "This means that you will need to reauthorize every time.\n";
        print "\n";
        $passphrase = prompt("Enter passphrase (to encrypt your code): ", -echo=>'*');
        if ($passphrase eq "") {
            $passphrase2 = "";
        }
        else {
            $passphrase2 = prompt("Reenter passphrase: ", -echo=>'*');
        }
        print "\n";
    }
    if ($passphrase eq "") {
        print "Code was not saved.\n";
    }
    else {
        my $encrypted = encrypt(freeze($token),$passphrase);
        mkdir_p(dirname($tokenfile));
        open(FH, "> $tokenfile");
        print FH $encrypted;
        close (FH);
    }
}

# mkdir -p equivalent
sub mkdir_p {
    my ($dir) = @_;
    if ( -d $dir) {
        return;
    }
    mkdir_p(dirname($dir));
    mkdir $dir;
}

# Log to file
sub logit {
    my ($logfile,$message) = @_;
    my $date = localtime();
    mkdir_p(dirname($logfile));
    open (LOG, ">> $logfile");
    printf LOG "%s\t%s\n", $date, $message;
    close LOG;
}

# Write failures
sub logfail {
    my ($failfile,$message) = @_;
    my $date = localtime();
    mkdir_p(dirname($logfile));
    open (LOG, ">> $logfile");
    printf LOG "%s\t%s\n", $date, $message;
    close LOG;
}

# Write default config
sub writeconfig {
    my ($configfile) = @_;
    mkdir_p(dirname($configfile));
    open (CONFIG, "> $configfile");
    print CONFIG <<EOF; 
# To create a new API client:
# - Go to https://console.developers.google.com/apis
# - Create a project
#   Project name: gmail-labeler
# - Credentials -> Create credentials -> OAuth client ID -> Other
# - Dashboard -> ENABLE API -> Gmail API -> ENABLE

# API client ID
# This can be found at https://console.developers.google.com/apis/credentials
# clientid 1234567890ab-1234567890abcdefghijklmnopqrstuv.apps.googleusercontent.com
clientid 1234567890ab-1234567890abcdefghijklmnopqrstuv.apps.googleusercontent.com

# API client secret
# This can be found at https://console.developers.google.com/apis/credentials
#clientsecret 1234-567890abcdefghijklm
clientsecret 1234-567890abcdefghijklm

# Where to save google token
# token ~/.gmail-labeler/.gmail-labeler.token
token ~/.gmail-labeler/.gmail-labeler.token

# Encrypted token passphrase (make this unique as it's cleartext)
# passwd mysuperawesomepasshrase

# Path to logfile
# logfile ~/.gmail-labeler/.gmail-labeler.log
logfile ~/.gmail-labeler/.gmail-labeler.log

# Path to failure log
# failfile ~/.gmail-labeler/failure.log
failfile ~/.gmail-labeler/failure.log

# Print out debug messages.  Default is 0.
# debug 0
EOF
    close CONFIG;
    chmod 0600, $configfile;
}



