#!/usr/bin/env raku

use lib '/home/mdevine/github.com/ISP-dsmadmc/lib';
use ISP::dsmadmc;
use Data::Dump::Tree;

my ISP::dsmadmc $dsmadmc .= new(:isp-server('isplc02'), :isp-admin('A028441'));
#my ISP::dsmadmc $dsmadmc .= new(:isp-admin('A028441'));
ddt $dsmadmc.execute(<QUERY EVENT * * BEGINDATE=TODAY-2 FORMAT=DETAILED>);
