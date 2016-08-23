# gmail-labeler
This can be used to modify the Gmail labels of a message via the Gmail API.

## Requirements
- Perl
- module Data::Dumper
- module Google::API::Client
- module Google::API::OAuth2::Client
- module Config::Simple
- module Storable
- module Crypt::CBC
- module IO::Prompter
- module Getopt::Long
- module File::Basename
- module Crypt::OpenSSL::AES

## Using gmail-labeler

### Create a new Google API client
- Go to https://console.developers.google.com/apis
- Create a project.  Project name: gmail-labeler
- Credentials -> Create credentials -> OAuth client ID -> Other
- Dashboard -> ENABLE API -> Gmail API -> ENABLE

### Run it for the first time to generate a config file
    ./gmail-labeler.pl

### Edit the config file with your clientid and clientsecret
    vi ~/.gmail-labelerrc

### Run it again
    ./gmail-labeler.pl

## Other gmail-labeler options

### Run with a non-default .gmail-labelerrc
    ./gmail-labeler.pl -f /path/to/gmail-labelerrc

### List all possible Gmail labels
    ./gmail-labeler.pl -l

### Label message (add to newlabel and remove from INBOX)
    ./gmail-labeler.pl -i 1234567890abcdef -a "newlabel" -r "INBOX"

### Label message (add to label1,label2)
    ./gmail-labeler.pl -i 1234567890abcdef -a "label1,label2"

### Perform dry run to see what it will change
    ./gmail-labeler.pl -d -i 1234567890abcdef -a "newlabel"

### Provide token passphrase on command line (unsafe option)
    ./gmail-labeler.pl -p mysuperawesomepassphrase

## Configuration file options

Default configuration file is ~/.gmail-labelerrc, but you may specify it as an argument.

### clientid 1234567890ab-1234567890abcdefghijklmnopqrstuv.apps.googleusercontent.com
- API client ID

### clientsecret 1234-567890abcdefghijklm
- API client secret

### token ~/.gmail-labeler/.gmail-labeler.token
- Where to save google token

### passwd mysuperawesomepasshrase
- Encrypted token passphrase (make this unique as it's cleartext)

### logfile ~/.gmail-labeler/.gmail-labeler.log
- Path to logfile

### failfile ~/.gmail-labeler/failure.log
- Path to failure log

### debug 0
- Print out debug messages.  Default is 0.
