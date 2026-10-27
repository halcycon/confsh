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

# WireGuard, guest network (zone + forwarding), DSA VLANs, wireless.
out=$(cs <<'EOF'
configure
set network interface wg0 proto wireguard
set network interface wg0 private_key SERVER_PRIVATE_KEY=
set network interface wg0 listen_port 51820
set network interface wg0 addresses 10.0.0.1/24
set network wireguard_wg0 laptop public_key LAPTOP_PUBLIC_KEY=
set network wireguard_wg0 laptop description "Adam laptop"
set network wireguard_wg0 laptop allowed_ips 10.0.0.2/32
set network wireguard_wg0 laptop route_allowed_ips 1
set network wireguard_wg0 site_b public_key SITE_B_PUBLIC_KEY=
set network wireguard_wg0 site_b endpoint_host vpn.example.com
set network wireguard_wg0 site_b endpoint_port 51820
set network wireguard_wg0 site_b persistent_keepalive 25
set network wireguard_wg0 site_b allowed_ips 10.0.0.3/32
set network wireguard_wg0 site_b allowed_ips 192.168.50.0/24
set network wireguard_wg0 site_b route_allowed_ips 1
set firewall zone @0 network wg0
set firewall rule wg_in name Allow-WireGuard
set firewall rule wg_in src wan
set firewall rule wg_in proto udp
set firewall rule wg_in dest_port 51820
set firewall rule wg_in target ACCEPT
commit comment wireguard
delete network wireguard_wg0 site_b allowed_ips 192.168.50.0/24
delete network wireguard_wg0 laptop
set network interface guest proto static
set network interface guest ipaddr 192.168.30.1
set network interface guest netmask 255.255.255.0
set dhcp dhcp guest interface guest
set dhcp dhcp guest start 100
set dhcp dhcp guest limit 50
set firewall zone guest name guest
set firewall zone guest network guest
set firewall zone guest input REJECT
set firewall zone guest output ACCEPT
set firewall zone guest forward REJECT
set firewall forwarding guest_wan src guest
set firewall forwarding guest_wan dest wan
set firewall rule guest_dns name Guest-DNS
set firewall rule guest_dns src guest
set firewall rule guest_dns dest_port 53
set firewall rule guest_dns target ACCEPT
set firewall rule guest_dhcp name Guest-DHCP
set firewall rule guest_dhcp src guest
set firewall rule guest_dhcp proto udp
set firewall rule guest_dhcp dest_port 67
set firewall rule guest_dhcp target ACCEPT
set wireless wifi-device radio0 disabled 0
set wireless wifi-device radio0 country GB
set wireless wifi-device radio0 channel 6
set wireless wifi-iface default_radio0 ssid HomeNet
set wireless wifi-iface default_radio0 encryption sae-mixed
set wireless wifi-iface default_radio0 key "correct horse battery staple"
set wireless wifi-iface guest_radio0 device radio0
set wireless wifi-iface guest_radio0 mode ap
set wireless wifi-iface guest_radio0 network guest
set wireless wifi-iface guest_radio0 ssid Guest
set wireless wifi-iface guest_radio0 encryption psk2
set wireless wifi-iface guest_radio0 key "guest password"
set wireless wifi-iface guest_radio0 isolate 1
set network bridge-vlan lan_vlan1 device br-lan
set network bridge-vlan lan_vlan1 vlan 1
set network bridge-vlan lan_vlan1 ports 'eth0:u*'
set network bridge-vlan lan_vlan1 ports 'eth1:u*'
set network bridge-vlan lan_vlan20 device br-lan
set network bridge-vlan lan_vlan20 vlan 20
set network bridge-vlan lan_vlan20 ports eth1:t
set network interface lan device br-lan.1
set network interface cams device br-lan.20
set network interface cams proto static
set network interface cams ipaddr 192.168.40.1
set network interface cams netmask 255.255.255.0
commit comment "guest, wifi, vlans"
EOF
) || fail "cheat-sheet part 2 failed: $out"

eq "$(uci get network.wg0.addresses)" "10.0.0.1/24"
eq "$(uci get network.site_b.allowed_ips)" "10.0.0.3/32"
eq "$(uci get network.site_b.persistent_keepalive)" "25"
uci -q get network.laptop && fail "laptop peer should be deleted"
eq "$(uci get firewall.@zone[0].network)" "lan iot wg0"
eq "$(uci get firewall.guest_wan.dest)" "wan"
eq "$(uci get dhcp.guest.limit)" "50"
eq "$(uci get wireless.default_radio0.key)" "correct horse battery staple"
eq "$(uci get wireless.guest_radio0.network)" "guest"
eq "$(uci get network.lan_vlan1.ports)" "eth0:u* eth1:u*"
eq "$(uci get network.lan.device)" "br-lan.1"
eq "$(uci get network.cams.device)" "br-lan.20"
