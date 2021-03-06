#!/bin/sh
# Crapulator Setup
# Use rpi to connect to available WLAN, USB cell stick, or a USB-tethered cell phone
# include WAN performance degradation scripts

# Prior to this:
# 1) Image raspbian stretch on a microSD card
# 2) edit WPA supplicant. copy wpa_supplicant.conf & ssh files onto the microSD before first boot.
# 3) boot, ssh to pi, sudo su, copy this script and run it
# or curl -sSL https://raw.github.com/rylatorr/crapulator/master/crapulator.sh | bash

# If the user's id is zero,
if [[ "${EUID}" -eq 0 ]]; then
  # they are root and all is good
  echo "Beginning setup"
else
  echo "Script called with non-root privileges. Become root with sudo su"
  exit 1
fi

# Update apt and install packages
apt-get update  # To get the latest package lists
apt-get install isc-dhcp-server -y

# Add config to /etc/dhcpcd.conf
tee -a /etc/dhcpcd.conf << EOF

interface eth0
static ip_address=192.168.100.1/24
static routers= 192.168.100.0
static_domain_name_servers=192.168.100.1

interface eth1
static ip_address=192.168.200.1/24
static routers= 192.168.200.0
static_domain_name_servers=192.168.200.1
nolink
EOF

# Create persistent-net.rules config file to map a Huawei USB cell modem to eth5
tee -a /etc/udev/rules.d/70-persistent-net.rules << EOF
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTRS{manufacturer}=="HUAWEI_MOBILE", ATTR{dev_id}=="0x0", ATTR{type}=="1", KERNEL=="eth*", NAME="eth5"

EOF

# Create iptables config file
tee -a /etc/iptables << EOF

# Generated by iptables-save v1.4.21 on Sat Oct  8 13:24:46 2016
*filter
:INPUT ACCEPT [43:5619]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -i eth0 -o wlan0 -j ACCEPT
-A FORWARD -i eth0 -o usb0 -j ACCEPT
-A FORWARD -i eth0 -o eth5 -j ACCEPT
-A FORWARD -i wlan0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i usb0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i eth5 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
COMMIT
# Completed on Sat Oct  8 13:24:46 2016
# Generated by iptables-save v1.4.21 on Sat Oct  8 13:24:46 2016
*nat
:PREROUTING ACCEPT [27:1589]
:INPUT ACCEPT [25:1525]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o wlan0 -j MASQUERADE
-A POSTROUTING -o usb0 -j MASQUERADE
-A POSTROUTING -o eth5 -j MASQUERADE
COMMIT
# Completed on Sat Oct  8 13:24:46 2016
# Generated by iptables-save v1.4.21 on Sat Oct  8 13:24:46 2016
*mangle
:PREROUTING ACCEPT [48:6290]
:INPUT ACCEPT [46:6226]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT
# Completed on Sat Oct  8 13:24:46 2016

EOF

# Add config to /etc/rc.local for iptables restore
# first, remove the last line (exit 0)
sed -i '$ d' /etc/rc.local
tee -a /etc/rc.local << EOF

# restore IPTables
iptables-restore < /etc/iptables

# hack to start DHCP server
sleep 10
service isc-dhcp-server start

exit 0

EOF

# Newer/better hack for isc-dhcp-server issue
cp /run/systemd/generator.late/isc-dhcp-server.service /etc/systemd/system
sed -i 's/Restart=no/Restart=on-failure/g' /etc/systemd/system
tee -a /etc/systemd/system << EOF
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl disable isc-dhcp-server
systemctl enable isc-dhcp-server

# Enable ip forwarding by uncommenting net.ipv4.ip_forward=1
sed -i '/^#.*net.ipv4.ip_forward=1/s/^#//' /etc/sysctl.conf

# replace config for /etc/dhcp/dhcpd.conf
tee /etc/dhcp/dhcpd.conf << EOF

# Configuration file for ISC dhcpd for Debian
ddns-update-style none;

#change option domain-name as desired
option domain-name "meraki.local";
option domain-name-servers 208.67.220.220, 208.67.222.222;

default-lease-time 600;
max-lease-time 7200;

authoritative;

log-facility local7;

#configure service for network 192.168.100.0 (ethernet port serving MX WAN)
subnet 192.168.100.0 netmask 255.255.255.0{
 range 192.168.100.10 192.168.100.50;
 option routers 192.168.100.1;
}

#configure service for network 192.168.200.0 (the mgmt ethernet port)
subnet 192.168.200.0 netmask 255.255.255.0{
 range 192.168.200.10 192.168.200.50;
}

EOF

# Enable ISC DHCP server to run on eth0 and eth1 (mgmt interface)
sed -i '/^INTERFACESv4=.*/c\INTERFACESv4="eth0 eth1"' /etc/default/isc-dhcp-server

# Disable slow boot (raspi-config do_boot_wait)
rm -f /etc/systemd/system/dhcpcd.service.d/wait.conf
# Enable & start DHCP server
update-rc.d isc-dhcp-server enable
service isc-dhcp-server start

# Scripts for easy demo of WAN brownout
tee -a /home/pi/bad-performance.sh << EOF
#BAD PERFORMANCE on WAN2:
sudo tc qdisc del dev eth0 root
sudo tc qdisc add dev eth0 root handle 1:0 tbf rate 10Mbit burst 100K latency 5000ms
sudo tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 300ms 250ms loss 65%
EOF
tee -a /home/pi/good-performance.sh << EOF
#GOOD PERFORMANCE on WAN2:
sudo tc qdisc del dev eth0 root
sudo tc qdisc add dev eth0 root handle 1:0 tbf rate 100Mbit burst 100K latency 5ms
sudo tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 0ms 5ms loss 0
EOF
chmod +x /home/pi/bad-performance.sh /home/pi/good-performance.sh

# Configure a recognizable hostname
sed -i 's/raspberrypi/crapulator/g' /etc/hostname
sed -i "s/127.0.1.1.*raspberrypi/127.0.1.1\tcrapulator/g" /etc/hosts

# Finish up
echo "Setup complete. Reboot."
