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
      "Usage: $command -i ID -l \"LABELS\" [-f .gmail-labelerrc] [-p PW]\n" .
      "  -i ID      Message ID to label\n" .
      "  -l LABELS  Labels in CSV format (comma-separated)\b" .
      "  -f         Path to a .gmail-labelerrc file\n" .
      "  -p PW      Provide password to token on the command line.  Not safe!\n" 
   );
   die("\n")
}

my $opt_labels = "";
my $opt_help;
my $opt_gmaillabelerrc;
my $opt_messageid = "";
my $opt_passwd = "";
Getopt::Long::GetOptions(
    'l=s' => \$opt_labels,
    'f=s' => \$opt_gmaillabelerrc,
    'i=s' => \$opt_messageid,
    'p=s' => \$opt_passwd,
    'h|help' => \$opt_help,
)
or usage("Invalid commmand line options.");
if ($opt_help) {
    usage("");
}
if ($opt_messageid =~ /^([a-zA-Z0-9]+)$/) {
    $opt_messageid = $1;
}
else {
    usage("Invalid message id.");
}
if ($opt_labels =~ /^([a-zA-Z0-9_,]+)$/) {
    $opt_labels = $1;
}
else {
    usage("Invalid labels.");
}

# Default variables
my $defaultconfig = $ENV{"HOME"} . "/.gmail-labelerrc";
my $clientid = "";
my $clientsecret = "";
my $tokenfile = $ENV{"HOME"} . ".gmail-labeler/token.dat";
my $passwd = "";
my $logfile = $ENV{"HOME"} . ".gmail-labeler/.gmail-labeler.log";
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
    $debug = $config->param('debug') || $debug;
}

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
        }
    }
};

# Set up client secrets
my $auth_driver = Google::API::OAuth2::Client->new(
    {
        auth_uri => 'https://accounts.google.com/o/oauth2/auth',
        token_uri => 'https://accounts.google.com/o/oauth2/token',
        client_id => $clientid,
        client_secret => $clientsecret,
        redirect_uri => "urn:ietf:wg:oauth:2.0:oob",
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

my @labels = split "/,/", $opt_labels;

labelmessage($opt_messageid,@labels);

exit;

sub labelmessage {
    my ($opt_messageid,@labels) = @_;
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

    my $code = prompt("Paste the code from google: ", -echo=>'*');
    print "\n";

    my $token = $auth_driver->exchange($code);
    if (! $token) {
        print "Token exchange rejected, try again.\n";
        exit;
    }

    my $passphrase = 1;
    my $passphrase2 = 2;
    until ($passphrase eq $passphrase2) {
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

# Print out debug messages.  Default is 0.
# debug 0
EOF
    close CONFIG;
    chmod 0600, $configfile;
}



