#!/usr/bin/env raku

use ISP::dsmadmc;
use Data::Dump::Tree;

#my ISP::dsmadmc $dsmadmc .= new(:isp-admin('ISPMON'));
my ISP::dsmadmc $dsmadmc .= new(:isp-server('ISPLC01'), :isp-admin('ISPMON'), :cache(True));
ddt $dsmadmc.execute(<QUERY LOG FORMAT=DETAILED>);
