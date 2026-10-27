# SPDX-License-Identifier: MIT
# Every example in docs/COMMANDS.md "EdgeOS cheat-sheet" must work on a
# stock-layout config (stock dhcp/dropbear from the image).
. /src/tests/lib.sh

out=$(cs <<'EOF'
configure
set system system @0 hostname gw1
set system system @0 zonename Europe/London
set system system @0 timezone GMT0BST,M3.5.0/1,M10.5.0
set system timeserver ntp server 0.uk.pool.ntp.org
set network interface lan ipaddr 192.168.10.1
set network interface lan netmask 255.255.255.0
set network interface wan proto dhcp
set network interface lan dns 1.1.1.1
set network device vlan10 type 8021q
set network device vlan10 ifname eth1
set network device vlan10 vid 10
set network device vlan10 name eth1.10
set network interface iot device eth1.10
set network interface iot proto static
set network interface iot ipaddr 192.168.20.1
set network interface iot netmask 255.255.255.0
set firewall zone @0 network iot
set dhcp dhcp lan start 100
set dhcp dhcp lan limit 100
set dhcp dhcp lan leasetime 12h
set dhcp host printer name printer
set dhcp host printer mac 00:11:22:33:44:55
set dhcp host printer ip 192.168.10.20
set dhcp dnsmasq @0 server 1.1.1.1
set network route corp interface lan
set network route corp target 10.0.0.0
set network route corp netmask 255.0.0.0
set network route corp gateway 192.168.10.254
set firewall zone @1 masq 1
set firewall redirect nas_https name NAS-HTTPS
set firewall redirect nas_https src wan
set firewall redirect nas_https proto tcp
set firewall redirect nas_https src_dport 443
set firewall redirect nas_https dest lan
set firewall redirect nas_https dest_ip 192.168.10.10
set firewall redirect nas_https dest_port 443
set firewall redirect nas_https target DNAT
set firewall rule allow_ssh name Allow-SSH-WAN
set firewall rule allow_ssh src wan
set firewall rule allow_ssh proto tcp
set firewall rule allow_ssh dest_port 22
set firewall rule allow_ssh target ACCEPT
set dropbear dropbear @0 Port 2222
set firewall defaults @0 flow_offloading 1
set firewall defaults @0 flow_offloading_hw 1
commit comment cheat-sheet
delete firewall rule allow_ssh
delete network interface lan dns 1.1.1.1
commit
EOF
) || fail "cheat-sheet script failed: $out"

eq "$(uci get system.@system[0].hostname)" "gw1"
eq "$(uci get network.lan.ipaddr)" "192.168.10.1"
eq "$(uci get network.vlan10.name)" "eth1.10"
eq "$(uci get firewall.@zone[0].network)" "lan iot"
eq "$(uci get dhcp.printer.ip)" "192.168.10.20"
eq "$(uci get dhcp.@dnsmasq[0].server)" "1.1.1.1"
eq "$(uci get network.corp.gateway)" "192.168.10.254"
eq "$(uci get firewall.nas_https.target)" "DNAT"
eq "$(uci get dropbear.@dropbear[0].Port)" "2222"
eq "$(uci get firewall.@defaults[0].flow_offloading_hw)" "1"
uci -q get firewall.allow_ssh && fail "allow_ssh should be deleted"
uci -q get network.lan.dns && fail "lan dns should be deleted"

# @N also addresses named sections (stock 25.12 dropbear is 'main').
contains "$(confsh show configuration commands dropbear dropbear @0)" "Port '2222'"
