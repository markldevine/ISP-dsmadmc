unit class ISP::dsmadmc:api<1>:auth<Mark Devine (mark@markdevine.com)>;

submethod TWEAK {
#   die "Install 'bind-utils' (or your OSes method) to provide 'dig' utility."
#       unless "/usr/bin/dig".IO.x || "/bin/dig".IO.x;
}

=finish
