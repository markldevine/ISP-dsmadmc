unit class ISP::dsmadmc:api<1>:auth<Mark Devine (mark@markdevine.com)>;

use ISP::Servers;
use KHPH;
use Terminal::ANSIColor;

has $!isp-server-inventory;

has $.isp-server    = '';
has $.isp-admin     is required;

submethod TWEAK {
    my $isp-servers = ISP::Servers.new;
    $!isp-server    = $isp-servers.isp-server($!isp-server);
    unless $!isp-server {
        $*ERR.put: colored('Unrecognized $!isp-server <' ~ $!isp-server ~ '> specified!', 'red');
        die colored('Either fix your --$isp-server=<value> or update Redis eb:isp:servers:*', 'red');
    }
    die "Set up '/opt/tivoli/tsm/client/ba/bin/dsm.sys' & /usr/bin/dsmadmc before using this script." unless '/opt/tivoli/tsm/client/ba/bin/dsm.sys'.IO.path:s;
    my @dsm-sys     = slurp('/opt/tivoli/tsm/client/ba/bin/dsm.sys').lines;
    my %stanzas;
    my $current-key = 'ERROR';
    for @dsm-sys -> $rcd {
        if $rcd ~~ m:i/ ^ SERVERNAME \s+ <alnum>+? '_' $<server>=(<alnum>+) \s* $ / {
            $current-key = $/<server>.Str.uc;
            next;
        }
        elsif $rcd ~~ m:i/ ^ \s* TCPS\w* \s+ $<value>=(.+) \s* $/ {
            %stanzas{$current-key}<TCPSERVERADDRESS> = $/<value>.Str;
        }
    }
    die 'SERVERNAME stanza containing $!isp-server <' ~ $!isp-server.uc ~ "> not found in '/opt/tivoli/tsm/client/ba/bin/dsm.sys'" unless %stanzas{$!isp-server}:exists;
}

method execute (@cmd!) {
    my $proc    = run
#                       '/usr/bin/stdbuf',
#                       '-i0',  
#                       '-o0',  
#                       '-e0',
                        '/usr/bin/dsmadmc',
                        '-SE=' ~ $!isp-admin ~ '_' ~ $!isp-server.uc,
                        '-ID=' ~ $!isp-admin,
                        '-PA=' ~ KHPH.new(:stash-path($*HOME ~ '/.isp/admin/' ~ $!isp-server.uc ~ '/' ~ $!isp-admin.uc ~ '.khph')).expose,
                        '-DATAONLY=YES',
                        '-DISPLAYMODE=LIST',
                        @cmd.flat,
                        :err,
                        :out;
    my @out;
    my $index   = 0;
    my $head-key;
    for $proc.out.lines -> $line {
        if $line ~~ / ^ \s* (.+?) ':' \s* (.*) \s* $ / {
            my $f1 = $/[0];
            my $f2 = Nil;
            if $/[1] {
                $f2 = $/[1];
            }
            if $head-key && $f1 eq $head-key {
                $index++;
            }
            elsif ! defined $head-key {
                $head-key = $f1;
                @out[$index] = Hash.new;
            }
            @out[$index]{$f1} = $f2;
        }
    }
    my $err     = $proc.err.slurp(:close);
    put $err    if $err;
    return(@out) if @out.elems;
    return Nil;
}

=finish
