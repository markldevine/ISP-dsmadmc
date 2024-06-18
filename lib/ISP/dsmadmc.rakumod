unit class ISP::dsmadmc:api<1>:auth<Mark Devine (mark@markdevine.com)>;

use ISP::Servers;
use KHPH;
use Our::Cache;

has Str     $.isp-server            = '';
has Str:D   $.isp-admin             is required;

#   DB2 (ISP's database engine) handles timezone specification in typical
#   RDBMS fashion by storing the UTC offset in a compact way, requiring
#   conversion to the end user's format.
#
#   DB2 stores the timezone offset as a signed integer with a possible negative sign,
#   hours being variable 1 or 2 digits, minutes being 2 fixed digits, and seconds
#   being 2 fixed digits.
#
#   -*hh*mmss
#
#   Being a signed integer, conversion is required before it is useful.

has Int     $.db2-timezone-integer;     # DB2's original internal representation of the timezone
has Str     $.timezone-hhmmss;          # "-05:00" format
has Int     $.seconds-offset-UTC;       # seconds from UTC
has Bool    $.cache     = False;        # read cache from previous execution results

submethod TWEAK {
    my $isp-servers     = ISP::Servers.new();
    $!isp-server        = $isp-servers.isp-server($!isp-server);
    my $identifier      = 'DB2timezone';
    my $db2-cache       = Our::Cache.new(:$identifier);
    if $db2-cache.cache-hit {
        $!db2-timezone-integer = $db2-cache.fetch(:$identifier).Int;
    }
    else {
        my @command =   '/usr/bin/dsmadmc',
           '-SE=' ~ $!isp-admin ~ '_' ~ $!isp-server.uc,
           '-ID=' ~ $!isp-admin,
           '-PA=' ~ KHPH.new(:stash-path($*HOME ~ '/.isp/admin/' ~ $!isp-server.uc ~ '/' ~ $!isp-admin.uc ~ '.khph')).expose,
           '-DATAONLY=YES',
           '-DISPLAYMODE=LIST',
           'SELECT', 'CURRENT', 'TIMEZONE', 'AS', 'TIMEZONE', 'FROM', 'SYSIBM.SYSDUMMY1';
        my $proc    = run @command, :out;
        my $stdout  = slurp $proc.out, :close;      # Str $stdout = "TIMEZONE: -50000\n\n"
        if $stdout ~~ / ^ 'TIMEZONE:' \s+ ('-'*\d+) / {
            $!db2-timezone-integer = $0.Int;
            $db2-cache.store(:$identifier, :data($!db2-timezone-integer.Str), :expire-after(DateTime(now + (60 * 60 * 24))));
        }
    }
    die 'Could not obtain DB2 TIMEZONE (SELECT CURRENT TIMEZONE AS TIMEZONE FROM SYSIBM.SYSDUMMY1)' unless $!db2-timezone-integer;
    my $h;
    my $m;
    my $s;
    ($h, $m, $s) = $!db2-timezone-integer.Str.flip.comb(2).flip.split(' ');
    $!timezone-hhmmss = $h ~ ':' ~ $m ~ ':' ~ $s;
    if $h < 0 {
        $!seconds-offset-UTC = -1 * (($h.abs * 3600) + ($m * 60) + $s);
    }
    else {
        $!seconds-offset-UTC = (($h * 3600) + ($m * 60) + $s);
    }
}

#%%%    method execute-fh (@cmd!) {
method execute (@cmd!, Str :$subdir, DateTime :$expire-after) {
    my $identifier              = @cmd.flat.join;
    my $dsmadmc-cache           = Our::Cache.new(:$identifier);
    unless self.cache && $dsmadmc-cache.cache-hit {
        my $path                = $dsmadmc-cache.temp-write-path or die;
        my $proc                = run
                                    '/usr/bin/dsmadmc',
                                    '-SE=' ~ $!isp-admin ~ '_' ~ $!isp-server.uc,
                                    '-ID=' ~ $!isp-admin,
                                    '-PA=' ~ KHPH.new(:stash-path($*HOME ~ '/.isp/admin/' ~ $!isp-server.uc ~ '/' ~ $!isp-admin.uc ~ '.khph')).expose,
                                    '-DATAONLY=YES',
                                    '-DISPLAYMODE=LIST',
                                    '-OUTFILE=' ~ $path.Str,
                                    @cmd.flat,
                                    :err;
        my $err                 = $proc.err.slurp(:close);
        die $err                if $err;
        $dsmadmc-cache.store(:$identifier, :$expire-after, :purge-source, :$path);
    }

    my $fh                      = $dsmadmc-cache.fetch-fh(:$identifier);

    my @data;
    my $index                   = 0;
    my $head-key;
    while !$fh.eof {
        my $record              = $fh.get;
        next                    unless $record;
        if $record ~~ / ^ \s* (.+?) ':' \s* (.*) \s* $ / {
            my $f1              = $/[0].Str;
            my $f2              = $/[1].Str // '';
            $f2                 = DateTime.new(:year($0.Int), :month($1.Int), :day($2.Int), :hour($3.Int), :minute($4.Int), :second($5.Int), :timezone(self.seconds-offset-UTC))
                if $f2 ~~ / ^ (\d ** 4) '-' (\d ** 2) '-' (\d ** 2) \s+ (\d ** 2) ':' (\d ** 2) ':' (\d ** 2) /;
            if $head-key && $f1 eq $head-key {
                $index++;
            }
            elsif ! defined $head-key {
                $head-key       = $f1;
                @data[$index]   = Hash.new;
            }
            @data[$index]{$f1}  = $f2;
        }
    }
    $fh.close;
    return @data                if @data.elems;
    return Nil;
}

=finish
