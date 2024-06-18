#!/usr/bin/env raku

#use lib '/home/mdevine/github.com/ISP-dsmadmc/lib';

use ISP::dsmadmc;
use Data::Dump::Tree;

#my ISP::dsmadmc $dsmadmc .= new(:isp-admin('ISPMON'));
my ISP::dsmadmc $dsmadmc .= new(:isp-server('ISPLC01'), :isp-admin('ISPMON'), :cache(True));
#ddt $dsmadmc.execute(<select NODE_NAME,EMAIL_ADDRESS from NODES>);
ddt $dsmadmc.execute(<QUERY DB FORMAT=DETAILED>);
