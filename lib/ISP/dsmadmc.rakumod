unit class ISP::dsmadmc:api<1>:auth<Mark Devine (mark@markdevine.com)>;

use KHPH;
use Terminal::ANSIColor;

my @redis-servers;
my %isp-servers;

has $.isp-server is required;
has $.isp-admin  is required;

submethod TWEAK {
    if "$*HOME/.redis-servers".IO.f {
        @redis-servers = slurp("$*HOME/.redis-servers").chomp.split("\n");
    }
    else {
        die 'Unable to initialized without ~/.redis-servers';
    }
    my @redis-clis;
    for @redis-servers -> $redis-server {
        my @cmd-string = sprintf("ssh -L 127.0.0.1:6379:%s:6379 %s /usr/bin/redis-cli", $redis-server, $redis-server).split: /\s+/;
        @redis-clis.push: @cmd-string;
    }
    for @redis-clis -> @redis-cli {
        my @rcmd        = flat @redis-cli,
                        '--raw',
                        'KEYS',
                        'eb:isp:servers:*';
        my $proc        = run   @rcmd, :out, :err;
        my $out         = $proc.out.slurp(:close);
        my $err         = $proc.err.slurp(:close);
        fail 'FAILED: ' ~ @rcmd ~ ":\t" ~ $err if $err;
        if $out {
            my @ispssks = $out.chomp.split("\n");
            die "No ISP server site keys!" unless @ispssks;
            @rcmd   = flat @redis-cli,
                    '--raw',
                    'SUNION',
                    @ispssks;
            $proc    = run   @rcmd, :out, :err;
            $out     = $proc.out.slurp(:close);
            $err     = $proc.err.slurp(:close);
            fail 'FAILED: ' ~ @rcmd ~ ":\t" ~ $err if $err;
            if $out {
                %isp-servers = $out.chomp.split("\n").map: { $_.uc => 0 };
                last;
            }
        }
    }
    unless %isp-servers{$!isp-server.uc}:exists {
        $*ERR.put: colored('Unrecognized $!isp-server <' ~ $!isp-server ~ '> specified!', 'red');
        die colored('Either fix your --$isp-server=<value> or update Redis eb:isp:servers:*', 'red');
    }
    die "Set up '/opt/tivoli/tsm/client/ba/bin/dsm.sys' & /usr/bin/dsmadmc before using this script." unless '/opt/tivoli/tsm/client/ba/bin/dsm.sys'.IO.path:s;
    my @dsm-sys     = slurp('/opt/tivoli/tsm/client/ba/bin/dsm.sys').lines;
    my %stanzas;
    my $current-key = 'ERROR';
    for @dsm-sys -> $rcd {
        if $rcd ~~ m:i/ ^ SERVERNAME \s+ <alnum>+? '_' $<server>=(<alnum>+) \s* $ / {
            $current-key = $/<server>.Str;
            next;
        }
        elsif $rcd ~~ m:i/ ^ \s* TCPS\w* \s+ $<value>=(.+) \s* $/ {
            %stanzas{$current-key}<TCPSERVERADDRESS> = $/<value>.Str;
        }
    }
    unless %stanzas{$!isp-server.uc}:exists {
        warn "Use any of:"
        .warn for %stanzas.keys;
        die 'SERVERNAME stanza containing $!isp-server <' ~ $!isp-server.uc ~ "> not found in '/opt/tivoli/tsm/client/ba/bin/dsm.sys'";
    }
}

method execute (@cmd!) {
    my $proc    = run   '/usr/bin/dsmadmc',
                        '-SE=' ~ $!isp-admin ~ '_' ~ $!isp-server.uc,
                        '-ID=' ~ $!isp-admin,
                        '-PA=' ~ KHPH.new(:stash-path($*HOME ~ '/.isp/admin/' ~ $!isp-server.uc ~ '/' ~ $!isp-admin.uc ~ '.khph')).expose,
                        '-DATAONLY=YES',
                        '-DISPLAYMODE=LIST',
                        @cmd.flat,
                        :err,
                        :out;
    my $err     = $proc.err.slurp(:close);
    put $err    if $err;
    my $out     = $proc.out.slurp(:close);
    if $out {
        my @out;
        my $out-index   = 0;
        my $head-key;
        for $out.split("\n") -> $line {
            if $line ~~ / ^ \s* (.+?) ':' \s+ (.+) \s* $ / {
                my $f1 = $/[0];
                my $f2 = $/[1];
                if $head-key && $f1 eq $head-key {
                    $out-index++;
                }
                elsif ! defined $head-key {
                    $head-key = $f1;
                    @out[$out-index] = Hash.new;
                }
                @out[$out-index]{$f1} = $f2;
            }
        }
        return(@out);
    }
}

=finish
