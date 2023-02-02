unit class ISP::dsmadmc:api<1>:auth<Mark Devine (mark@markdevine.com)>;

use KHPH;
use Terminal::ANSIColor;
use Prettier::Table;
use Data::Dump::Tree;
#use Grammar::Debugger;
#use Grammar::Tracer;

my @redis-servers;
my %isp-servers;
my @dns-servers;
my @dns-domains;

submethod TWEAK {
    if "$*HOME/.redis-servers".IO.f {
        @redis-servers = slurp("$*HOME/.redis-servers");
    }
    else {
        die 'Unable to initialized without ~/.redis-servers';
    }
}

=finish;

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
        @rcmd    = flat @redis-cli,
                   '--raw',
                   'SUNION',
                   @ispssks;
        $proc    = run   @rcmd, :out, :err;
        $out     = $proc.out.slurp(:close);
        $err     = $proc.err.slurp(:close);
        fail 'FAILED: ' ~ @rcmd ~ ":\t" ~ $err if $err;
        if $out {
            %isp-servers = $out.chomp.split("\n").map: { $_ => 0 };
            last;
        }
    }
}

for @redis-clis -> @redis-cli {
    my @rcmd    = flat @redis-cli,
                  '--raw',
                  'SMEMBERS',
                  'wmata:dns:domains';
    my $proc    = run   @rcmd, :out, :err;
    my $out     = $proc.out.slurp(:close);
    my $err     = $proc.err.slurp(:close);
    fail 'FAILED: ' ~ @rcmd ~ ":\t" ~ $err if $err;
    if $out {
        @dns-domains = $out.chomp.split: "\n";
        last;
    }
}
for @redis-clis -> @redis-cli {
    my @rcmd    = flat @redis-cli,
                  '--raw',
                  'SMEMBERS',
                  'wmata:dns:servers';
    my $proc    = run   @rcmd, :out, :err;
    my $out     = $proc.out.slurp(:close);
    my $err     = $proc.err.slurp(:close);
    fail 'FAILED: ' ~ @rcmd ~ ":\t" ~ $err if $err;
    if $out {
        @dns-servers = $out.chomp.split: "\n";
        last;
    }
}

#   SCHEDULED_START: 2023-01-23 20:00:00.000000
#      ACTUAL_START: 
#       DOMAIN_NAME: EVAULT
#     SCHEDULE_NAME: SCH_2000
#         NODE_NAME: JGDCIEVAULT01PV
#            STATUS: Missed
#            RESULT: 
#            REASON: 
#         COMPLETED: 2023-01-23 21:00:00.000000


#   Grammars

grammar DATE-TIME   {
    token TOP {
                ^
                <month>     = (\d\d)
                '/'
                <day>       = (\d\d)
                '/'
                <year>      = (\d+)
                \s+
                <hours>     = (\d\d)
                ':'
                <minutes>   = (\d\d)
                ':'
                <seconds>   = (\d\d)
                $
              }
}

sub MAIN (
    Str:D   :$isp-server!,  #= ISP server name
    Str:D   :$domain,       #= ISP DOMAIN name
    Str:D   :$node,         #= ISP NODE name
) {
    my $proc;
    my $err;
    my $out;

#   Sort out the ISP server info

    my $SERVER_NAME = $isp-server-name.uc;
    unless %isp-servers{$SERVER_NAME}:exists {
        $*ERR.put: colored('Unrecognized $isp-server-name <' ~ $isp-server-name ~ '> specified!', 'red');
        die colored('Either fix your --$isp-server-name=<value> or update Redis eb:isp:servers:*', 'red');
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
    unless %stanzas{$SERVER_NAME}:exists {
        warn "Use any of:"
        .warn for %stanzas.keys;
        die 'SERVERNAME stanza containing $isp-server-name <' ~ $SERVER_NAME ~ "> not found in '/opt/tivoli/tsm/client/ba/bin/dsm.sys'";
    }
    my $resolved-server-ip-label;
    my $resolved-server-ip-address;
    if %stanzas{$SERVER_NAME}<TCPSERVERADDRESS> ~~ m/ ^ (\d ** 1..3 '.' \d ** 1..3 '.' \d ** 1..3 '.' \d ** 1..3) $ / {
        $resolved-server-ip-address = $/.Str;
        $resolved-server-ip-label   = lookup-reverse($resolved-server-ip-address, :expectation($SERVER_NAME));
    }
    elsif %stanzas{$SERVER_NAME}<TCPSERVERADDRESS> ~~ m/ ^ <[\w.]>+ $ / {
        $resolved-server-ip-address = lookup-forward(%stanzas{$SERVER_NAME}<TCPSERVERADDRESS>);
        $resolved-server-ip-label = lookup-reverse($resolved-server-ip-address, :expectation($SERVER_NAME));
    }
    die "Unable to resolve IP information for $SERVER_NAME stanza in '/opt/tivoli/tsm/client/ba/bin/dsm.sys'" unless $resolved-server-ip-label && $resolved-server-ip-address;

#%% WHAT IF $isp-server-if-ip-label || $isp-server-if-ip-address IS OFFERED BY THE USER????
#   - if $isp-server-if-ip-address
#       - unless $isp-server-if-ip-address eq $resolved-server-ip-label
#           - resolve PTR to label
#           - if $isp-server-if-ip-label was offered as well, canonicalize it & die unless it agrees with DNS
#           - sudo ping -q -c 1 -w 1 -i 1  $isp-server-if-ip-address or die
#           - $resolved-server-ip-address = $isp-server-if-ip-address && $resolved-server-ip-address = canonicalized label from this block
#   - elsif $isp-server-if-ip-label 
#       - unless $isp-server-if-ip-label eq $resolved-server-ip-label
#           - resolve A to IP address

# %%%%%%%%%%    what if name is different than A, because it's a CNAME?

#           - if sudo ping -q -c 1 -w 1 -i 1 <IP address from previous step>

#    $proc        = run   
##                       '/usr/bin/stdbuf',
##                       '-i0',
##                       '-o0',
##                       '-e0',
#                        '/usr/bin/dsmadmc',
#                        '-SE=' ~ $isp-admin ~ '_' ~ $SERVER_NAME,
#                        '-ID=' ~ $isp-admin,
#                        '-PA=' ~ KHPH.new(:stash-path($*HOME ~ '/.isp/admin/' ~ $SERVER_NAME ~ '/' ~ $isp-admin ~ '.khph')).expose,
#                        '-DATAONLY=YES',
#                        '-DISPLAYMODE=TABLE',
#                        '-TABDELIMITED',
#                        'SELECT',
#                        'SERVER_NAME',
#                        'FROM',
#                        'STATUS',
#                        :err,
#                        :out;
#    my $err         = $proc.err.slurp(:close);
#    my $out         = $proc.out.slurp(:close);
#    put 'Note: dsm.sys SERVERNAME stanza <' ~ $SERVER_NAME ~ '> ≠ <' ~ $out.chomp ~ "> ISP Server's SERVER_NAME" unless $SERVER_NAME eq $out.chomp;

#   Sort out the ISP client (NODE) info

    my $NODE_NAME   = $isp-node-name.uc;
    my $try-label   = $NODE_NAME;
    $try-label      = $isp-node-if-ip-label with $isp-node-if-ip-label;
    my $resolved-client-ip-address;
    my $resolved-client-ip-label;
    try {
        $resolved-client-ip-address = lookup-forward($try-label);
        $resolved-client-ip-label   = lookup-reverse($resolved-client-ip-address, :expectation($try-label));
        CATCH {
            warn "Unable to resolve IP information for $NODE_NAME" unless $resolved-client-ip-label && $resolved-client-ip-address;
        }
    }

    $proc   = run   
#                   '/usr/bin/stdbuf',
#                   '-i0',
#                   '-o0',
#                   '-e0',
                    '/usr/bin/dsmadmc',
                    '-SE=' ~ $isp-admin ~ '_' ~ $SERVER_NAME,
                    '-ID=' ~ $isp-admin,
                    '-PA=' ~ KHPH.new(:stash-path($*HOME ~ '/.isp/admin/' ~ $SERVER_NAME ~ '/' ~ $isp-admin ~ '.khph')).expose,
                    '-DATAONLY=YES',
                    '-DISPLAYMODE=TABLE',
                    '-TABDELIMITED',
                    'SELECT',
                    'NODE_NAME,SESSION_SECURITY',
                    'FROM',
                    'NODES',
                    'WHERE',
                    'NODE_NAME=' ~ q|'| ~ $NODE_NAME ~ q|'|,
                    :err,
                    :out;
    $err    = $proc.err.slurp(:close);
    $out    = $proc.out.slurp(:close);

    my $session-security;
    unless $proc.exitcode {
        my $node-name;
        ($node-name, $session-security) = $out.split: /\t/;
        $NODE_NAME                      = $node-name with $node-name;
    }

    my $table = Prettier::Table.new:
        title => "IBM Spectrum Protect Configuration Summary",
        field-names => ["ISP Server Name", "ISP Server IF Label", "ISP Server IF Address", "ISP Client Name", "ISP Client IF Label", "ISP Client IF Address"],
        align => %('ISP Server Name' => 'l'),
    ;

    given $table {
        .add-row: [
                    $SERVER_NAME,
                    $resolved-server-ip-label,
                    $resolved-server-ip-address,
                    $NODE_NAME,
                    $resolved-client-ip-label,
                    $resolved-client-ip-address
                  ];
    }
    put $table;

    with $NODE_NAME && $session-security {
        colored('UPDATE NODE ' ~ $NODE_NAME ~ ' SESSIONSECURITY=TRANSITIONAL', 'white on_black').put if $session-security !~~ /:i ^Transitional/;
    }
    else {
        colored('REGISTER NODE '
                ~ $NODE_NAME
                ~ ' '
                ~ KHPH.new(:stash-path($*HOME ~ '/.' ~ $*PROGRAM-NAME.IO.basename ~ '/defaults/' ~ $SERVER_NAME ~ '/NODE/password.khph')).expose
                ~ ' '
                ~ 'DOMAIN=%%%'
                ~ ' '
                ~ 'USER=NONE'
                ~ ' '
                ~ 'MAXNUMMP=1'
                ~ ' '
                ~ 'CONTACT="L%%%, F%%%%"'
                ~ ' '
                ~ 'EMAILADDRESS=%%%@%%%%%%.%%%'
                ~ ' '
                ~ 'SESSIONSECURITY=TRANSITIONAL', 'white on_black').put;
    }

    dsmgen(:$os,
           :isp-server-name($SERVER_NAME),
           :isp-server-ip-label($resolved-server-ip-label),
           :isp-server-ip-address($resolved-server-ip-address),
           :isp-client-name($NODE_NAME),
           :isp-client-ip-label($resolved-client-ip-label),
           :isp-client-ip-address($resolved-client-ip-address),
          );
}

multi sub dsmgen(
                    OS      :$os where $os.Str eq 'AIX',
                    Str:D   :$isp-server-name,
                    Str:D   :$isp-server-ip-label,
                    Str:D   :$isp-server-ip-address,
                    Str:D   :$isp-client-name,
                    Str:D   :$isp-client-ip-label,
                    Str:D   :$isp-client-ip-address,
                ) {
my @commands;
@commands[0] = qq:to/EODCODECREATE/;
cat > /usr/tivoli/tsm/client/ba/bin64/dsm.sys <<EODSMSYSCREATE
SERVERNAME {$isp-client-name.uc}_{$isp-server-name.uc}
    COMMMETHOD              TCPIP
    COMPRESSION             YES
    DEDUPCACHEPATH          /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
    DEDUPCACHESIZE          2048
    DEDUPLICATION           YES
    ENABLEINSTRUMENTATION   YES
    ERRORLOGNAME            /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
    ERRORLOGRETENTION       {$ERRORLOGRETENTION}
    INCLEXCL                /var/isp/ba/{$isp-client-name.uc}/INCLEXCL.ISP
    INSTRLOGMAX             {$INSTRLOGMAX}
    INSTRLOGNAME            /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
    MANAGEDSERVICES         SCHEDULE WEBCLIENT
    NODENAME                {$isp-client-name.uc}
*   PRESCHEDULECMD          /var/isp/ba/{$isp-client-name.uc}/presched.sh
*   POSTSCHEDULECMD         /var/isp/ba/{$isp-client-name.uc}/postsched.sh
    PASSWORDACCESS          GENERATE
    PASSWORDDIR             /var/isp/ba/{$isp-client-name.uc}/passwd
    RESOURCEUTILIZATION     1
    SCHEDLOGNAME            /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
    SCHEDLOGRETENTION       {$SCHEDLOGRETENTION}
    SHMPORT                 1510
    TCPCADADDRESS           {$isp-client-ip-label}
*   TCPCADADDRESS           {$isp-client-ip-address}
    TCPSERVERADDRESS        {$isp-server-ip-label}
*   TCPSERVERADDRESS        {$isp-server-ip-address}
    TXNBYTELIMIT            {$TXNBYTELIMIT}
EODSMSYSCREATE
chmod 644 /usr/tivoli/tsm/client/ba/bin64/dsm.sys
chown root:system /usr/tivoli/tsm/client/ba/bin64/dsm.sys
mkdir -p /var/isp
chmod 2750 /var/isp
chown root:system /var/isp
mkdir -p /var/isp/ba
chmod 2750 /var/isp/ba
chown root:system /var/isp/ba
mkdir -p /var/isp/ba/{$isp-client-name.uc}
chmod 2770 /var/isp/ba/{$isp-client-name.uc}
chown root:system /var/isp/ba/{$isp-client-name.uc}
mkdir -p /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
chmod 2770 /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
chown root:system /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
mkdir -p /var/isp/ba/{$isp-client-name.uc}/passwd
chmod 0700 /var/isp/ba/{$isp-client-name.uc}/passwd
chmod g-s /var/isp/ba/{$isp-client-name.uc}/passwd
chown root:system /var/isp/ba/{$isp-client-name.uc}/passwd
touch /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
chmod 660 /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
chown root:system /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
touch /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
chmod 660 /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
chown root:system /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
if [ ! -f /var/isp/ba/{$isp-client-name.uc}/presched.sh ] ; then echo -e '#!/bin/sh\\nexit 0' > /var/isp/ba/{$isp-client-name.uc}/presched.sh ; fi
chmod 740 /var/isp/ba/{$isp-client-name.uc}/presched.sh
chown root:system /var/isp/ba/{$isp-client-name.uc}/presched.sh
if [ ! -f /var/isp/ba/{$isp-client-name.uc}/postsched.sh ] ; then echo -e '#!/bin/sh\\nexit 0' > /var/isp/ba/{$isp-client-name.uc}/postsched.sh ; fi
chmod 740 /var/isp/ba/{$isp-client-name.uc}/postsched.sh
chown root:system /var/isp/ba/{$isp-client-name.uc}/postsched.sh
touch /var/isp/ba/{$isp-client-name}/INCLEXCL.ISP
chmod 640 /var/isp/ba/{$isp-client-name.uc}/INCLEXCL.ISP
chown root:system /var/isp/ba/{$isp-client-name.uc}/INCLEXCL.ISP
touch /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
chmod 640 /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
chown root:system /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
touch /var/isp/ba/{$isp-client-name.uc}/dsmwebcl.log
chmod 640 /var/isp/ba/{$isp-client-name.uc}/dsmwebcl.log
chown root:system /var/isp/ba/{$isp-client-name.uc}/dsmwebcl.log
echo SERVERNAME {$isp-client-name.uc}_{$isp-server-name.uc} > /usr/tivoli/tsm/client/ba/bin64/dsm.opt
chmod 644 /usr/tivoli/tsm/client/ba/bin64/dsm.opt
chown root:system /usr/tivoli/tsm/client/ba/bin64/dsm.opt
EODCODECREATE
@commands[1] = 'dsmc query session';
@commands[2] = 'mkitab "dsmcad::once:/usr/bin/dsmcad -optfile=/usr/tivoli/tsm/client/ba/bin64/dsm.opt"';
@commands[3] = '/usr/bin/dsmcad -optfile=/usr/tivoli/tsm/client/ba/bin64/dsm.opt';
colored(@commands[0], 'red').print;
colored(@commands[1], 'white on_red').put;
colored(@commands[2], 'red').put;
colored(@commands[3], 'red').put;
}

multi sub dsmgen(
                    OS      :$os where $os.Str eq 'Linux',
                    Str:D   :$isp-server-name,
                    Str:D   :$isp-server-ip-label,
                    Str:D   :$isp-server-ip-address,
                    Str:D   :$isp-client-name,
                    Str:D   :$isp-client-ip-label,
                    Str:D   :$isp-client-ip-address,
                ) {
    my $dsm-opt-file-name-ext   = '';
    $dsm-opt-file-name-ext      = '_' ~ $isp-client-name unless $isp-client-ip-label ~~ m:i/ ^ $isp-client-name /;
    my @commands;
    @commands[0] = qq:to/EODCODECREATE/;
    cat >> /opt/tivoli/tsm/client/ba/bin/dsm.sys <<EODSMSYSCREATE

    SERVERNAME {$isp-client-name.uc}_{$isp-server-name.uc}
        COMMMETHOD              TCPIP
        COMPRESSION             YES
        DEDUPCACHEPATH          /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
        DEDUPCACHESIZE          2048
        DEDUPLICATION           YES
        ENABLEINSTRUMENTATION   YES
        ERRORLOGNAME            /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
        ERRORLOGRETENTION       $ERRORLOGRETENTION
        HTTPPORT                1581
        INCLEXCL                /var/isp/ba/{$isp-client-name.uc}/INCLEXCL.ISP
        INSTRLOGMAX             {$INSTRLOGMAX}
        INSTRLOGNAME            /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
        MANAGEDSERVICES         SCHEDULE WEBCLIENT
        NODENAME                {$isp-client-name.uc}
    *   PRESCHEDULECMD          /var/isp/ba/{$isp-client-name.uc}/presched.sh
    *   POSTSCHEDULECMD         /var/isp/ba/{$isp-client-name.uc}/postsched.sh
        PASSWORDACCESS          GENERATE
        PASSWORDDIR             /var/isp/ba/{$isp-client-name.uc}/passwd
        RESOURCEUTILIZATION     1
        SCHEDLOGNAME            /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
        SCHEDLOGRETENTION       {$SCHEDLOGRETENTION}
        TCPCADADDRESS           {$isp-client-ip-label}
    *   TCPCADADDRESS           {$isp-client-ip-address}
        TCPSERVERADDRESS        {$isp-server-ip-label}
    *   TCPSERVERADDRESS        {$isp-server-ip-address}
        TXNBYTELIMIT            {$TXNBYTELIMIT}
        WEBPORTS                1582 1581
    EODSMSYSCREATE
    chmod 644 /opt/tivoli/tsm/client/ba/bin/dsm.sys
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /opt/tivoli/tsm/client/ba/bin/dsm.sys
    mkdir -p /var/isp
    chmod 2750 /var/isp
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp
    mkdir -p /var/isp/ba
    chmod 2750 /var/isp/ba
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba
    mkdir -p /var/isp/ba/{$isp-client-name.uc}
    chmod 2770 /var/isp/ba/{$isp-client-name.uc}
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}
    mkdir -p /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
    chmod 2770 /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/DEDUPCACHE
    mkdir -p /var/isp/ba/{$isp-client-name.uc}/passwd
    chmod 0700 /var/isp/ba/{$isp-client-name.uc}/passwd
    chmod g-s /var/isp/ba/{$isp-client-name.uc}/passwd
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/passwd
    touch /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
    chmod 660 /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/dsmerror.log
    touch /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
    chmod 660 /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/dsminstr.log
    touch /var/isp/ba/{$isp-client-name.uc}/dsminstr.log.lock
    chmod 660 /var/isp/ba/{$isp-client-name.uc}/dsminstr.log.lock
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/dsminstr.log.lock
    if [ ! -f /var/isp/ba/{$isp-client-name.uc}/presched.sh ] ; then echo -e '#!/bin/sh\\nexit 0' > /var/isp/ba/{$isp-client-name.uc}/presched.sh ; fi
    chmod 740 /var/isp/ba/{$isp-client-name.uc}/presched.sh
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/presched.sh
    if [ ! -f /var/isp/ba/{$isp-client-name.uc}/postsched.sh ] ; then echo -e '#!/bin/sh\\nexit 0' > /var/isp/ba/{$isp-client-name.uc}/postsched.sh ; fi
    chmod 740 /var/isp/ba/{$isp-client-name.uc}/postsched.sh
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/postsched.sh
    touch /var/isp/ba/{$isp-client-name}/INCLEXCL.ISP
    chmod 640 /var/isp/ba/{$isp-client-name.uc}/INCLEXCL.ISP
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/INCLEXCL.ISP
    touch /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
    chmod 640 /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/dsmsched.log
    touch /var/isp/ba/{$isp-client-name.uc}/dsmwebcl.log
    chmod 640 /var/isp/ba/{$isp-client-name.uc}/dsmwebcl.log
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /var/isp/ba/{$isp-client-name.uc}/dsmwebcl.log
    echo SERVERNAME {$isp-client-name.uc}_{$isp-server-name.uc} > /opt/tivoli/tsm/client/ba/bin/dsm{$dsm-opt-file-name-ext}.opt
    chmod 644 /opt/tivoli/tsm/client/ba/bin/dsm{$dsm-opt-file-name-ext}.opt
    chown root:DCI_GPO_BACKUPADMINS_DL_SG /opt/tivoli/tsm/client/ba/bin/dsm{$dsm-opt-file-name-ext}.opt
    EODCODECREATE
    @commands[1] = 'dsmc query session' ~ ' -optfile=/opt/tivoli/tsm/client/ba/bin/dsm' ~ $dsm-opt-file-name-ext ~ '.opt';
    if $dsm-opt-file-name-ext {
        @commands.push: "sed -e '/^### END INIT INFO\$/a \\\\nexport DSM_CONFIG=\/opt\/tivoli\/tsm\/client\/ba\/bin\/dsm{$dsm-opt-file-name-ext}.opt' /opt/tivoli/tsm/client/ba/bin/rc.dsmcad > /etc/init.d/dsmcad{$dsm-opt-file-name-ext}";
        @commands.push: qq|sed -i -e 's/^      daemon \$DSMCAD_BIN/      daemon \$DSMCAD_BIN -optfile=\$\{DSM_CONFIG\}/' /etc/init.d/dsmcad{$dsm-opt-file-name-ext}|;
        @commands.push: "chmod 755 /etc/init.d/dsmcad{$dsm-opt-file-name-ext}";
    }
    @commands.push: 'systemctl daemon-reload';
    @commands.push: "systemctl enable dsmcad{$dsm-opt-file-name-ext}";
    @commands.push: "systemctl start dsmcad{$dsm-opt-file-name-ext}";
    colored(@commands[0], 'cyan').print;
    colored(@commands[1], 'white on_cyan').put;
    for 2 .. @commands.elems - 1 {
        colored(@commands[$_], 'cyan').put;
    }
}

multi sub dsmgen(
                    OS      :$os where $os.Str eq 'Windows',
                    Str:D   :$isp-server-name,
                    Str:D   :$isp-server-ip-label,
                    Str:D   :$isp-server-ip-address,
                    Str:D   :$isp-client-name,
                    Str:D   :$isp-client-ip-label,
                    Str:D   :$isp-client-ip-address,
                ) {
    my @commands;
    my $ISP-CLIENT-NAME = $isp-client-name.uc;
    @commands[0] = Q:q:s:to/EODCODECREATE/;
    IF NOT EXIST "C:\Program Files\Tivoli\TSM\baclient\NODES" MKDIR "C:\Program Files\Tivoli\TSM\baclient\NODES"
    IF NOT EXIST "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]" MKDIR "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]"
    IF NOT EXIST "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\DEDUPCACHE" MKDIR "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\DEDUPCACHE"
    CD /D "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]
    IF EXIST dsm.opt COPY /Y dsm.opt dsm.opt.ORIG
    ECHO ******************************************************************************** > dsm.opt
    ECHO ***               Backup/Archive Client for local volumes only               *** >> dsm.opt
    ECHO ******************************************************************************** >> dsm.opt
    ECHO  CLUSTERNODE                  NO >> dsm.opt
    ECHO  COMMMETHOD                   TCPIP >> dsm.opt
    ECHO  COMPRESSION                  YES >> dsm.opt
    ECHO  DEDUPCACHEPATH               "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\DEDUPCACHE" >> dsm.opt
    ECHO  DEDUPCACHESIZE               2048 >> dsm.opt
    ECHO  DEDUPLICATION                YES >> dsm.opt
    ECHO  DOMAIN                       ALL-LOCAL >> dsm.opt
    ECHO  ENABLEDEDUPCACHE             YES >> dsm.opt
    ECHO  ENABLEINSTRUMENTATION        NO >> dsm.opt
    ECHO  ERRORLOGNAME                 "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\dsmerror.log" >> dsm.opt
    ECHO  ERRORLOGRETENTION            \qq[$ERRORLOGRETENTION] >> dsm.opt
    ECHO  HTTPPORT                     1581 >> dsm.opt
    ECHO  INCLEXCL                     "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\INCLEXCL.ISP" >> dsm.opt
    ECHO  INSTRLOGMAX                  \qq[$INSTRLOGMAX] >> dsm.opt
    ECHO  INSTRLOGNAME                 "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\dsminstr.log" >> dsm.opt
    ECHO  MANAGEDSERVICES              SCHEDULE WEBCLIENT >> dsm.opt
    ECHO  NODENAME                     \qq[$ISP-CLIENT-NAME] >> dsm.opt
    ECHO  PASSWORDACCESS               GENERATE >> dsm.opt
    ECHO  QUERYSCHEDPERIOD             4 >> dsm.opt
    ECHO *PRESCHEDULECMD               "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\PRESCHEDCMD.BAT" >> dsm.opt
    ECHO *POSTSCHEDULECMD              "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\POSTSCHEDCMD.BAT" >> dsm.opt
    ECHO  RESOURCEUTILIZATION          5 >> dsm.opt
    ECHO  SCHEDLOGNAME                 "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\dsmsched.log" >> dsm.opt
    ECHO  SCHEDLOGRETENTION            \qq[$SCHEDLOGRETENTION] >> dsm.opt
    ECHO  SCHEDMODE                    POLLING >> dsm.opt
    ECHO  SNAPSHOTPROVIDERFS           NONE >> dsm.opt
    ECHO  TCPBUFFSIZE                  32 >> dsm.opt
    ECHO  TCPCLIENTADDRESS             \qq[$isp-client-ip-label] >> dsm.opt
    ECHO *TCPCLIENTADDRESS             \qq[$isp-client-ip-address] >> dsm.opt
    ECHO  TCPPORT                      1500 >> dsm.opt
    ECHO  TCPSERVERADDRESS             \qq[$isp-server-ip-label] >> dsm.opt
    ECHO *TCPSERVERADDRESS             \qq[$isp-server-ip-address] >> dsm.opt
    ECHO  TCPWINDOWSIZE                0 >> dsm.opt
    ECHO  TXNBYTELIMIT                 \qq[$TXNBYTELIMIT] >> dsm.opt
    ECHO  WEBPORTS                     1582 1581 >> dsm.opt
    ECHO  INCLUDE.FS %SYSTEMDRIVE% SNAPSHOTPROVIDERFS=VSS > "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\INCLEXCL.ISP"
    WMIC product get name | FIND "Microsoft SQL Server" > NUL
    IF %ERRORLEVEL% EQU 0 (
        echo  EXCLUDE '*:\...\*.[Ll][Dd][Ff]' >> "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\INCLEXCL.ISP"
        echo  EXCLUDE '*:\...\*.[Mm][Dd][Ff]' >> "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\INCLEXCL.ISP"
        echo  EXCLUDE '*:\...\*.[Nn][Dd][Ff]' >> "C:\Program Files\Tivoli\TSM\baclient\NODES\\\qq[$ISP-CLIENT-NAME]\INCLEXCL.ISP"
    )
    EODCODECREATE
    @commands[1] = '"C:\Program Files\Tivoli\TSM\baclient\dsmc.exe" query session -optfile="C:\Program Files\Tivoli\TSM\baclient\NODES\\'
                    ~ $ISP-CLIENT-NAME
                    ~ '\dsm.opt"';
    @commands[2] = '"C:\Program Files\Tivoli\TSM\baclient\dsmcutil" install scheduler /name:"ISP Client Scheduler: '
                    ~ $ISP-CLIENT-NAME
                    ~ '" /node:'
                    ~ $ISP-CLIENT-NAME
                    ~ ' /password:"'
                    ~ KHPH.new(:stash-path($*HOME ~ '/.' ~ $*PROGRAM-NAME.IO.basename ~ '/defaults/' ~ $isp-server-name ~ '/NODE/password.khph')).expose
                    ~ '" /autostart:no /startnow:no /optfile:"C:\Program Files\Tivoli\TSM\baclient\NODES\\'
                    ~ $ISP-CLIENT-NAME
                    ~ '\dsm.opt"';
    @commands[3] = '"C:\Program Files\Tivoli\TSM\baclient\dsmcutil" install cad /name:"ISP Client Acceptor: '
                    ~ $ISP-CLIENT-NAME
                    ~ '" /node:'
                    ~ $ISP-CLIENT-NAME
                    ~ ' /password:"'
                    ~ KHPH.new(:stash-path($*HOME ~ '/.' ~ $*PROGRAM-NAME.IO.basename ~ '/defaults/' ~ $isp-server-name ~ '/NODE/password.khph')).expose
                    ~ '" /autostart:yes /startnow:yes /cadschedname:"ISP Client Scheduler: '
                    ~ $ISP-CLIENT-NAME
                    ~ '" /optfile:"C:\Program Files\Tivoli\TSM\baclient\NODES\\'
                    ~ $ISP-CLIENT-NAME
                    ~ '\dsm.opt"';
    colored(@commands[0], 'magenta').print;
    colored(@commands[1], 'white on_magenta').put;
    colored(@commands[2], 'magenta').put;
    colored(@commands[3], 'magenta').put;
}

=finish
