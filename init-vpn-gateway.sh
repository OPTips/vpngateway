#!/bin/bash

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root"
  exit 1
fi

echo "=== Universal VPN Gateway Initialization Script (Interactive + Ultimate No-Log) ==="

# 1. Get external interface automatically
EXT_IF=$(ip route show default | awk '/default/ {print $5}')
echo "External interface detected as: $EXT_IF"
echo "------------------------------------------------------------"

# 2. Dynamically list and select the internal interface
echo "Available internal interfaces:"
# Get all network interfaces, excluding loopback ('lo') and the external interface
AVAILABLE_IFS=$(ip -o link show | awk -F': ' '{print $2}' | grep -vw "lo" | grep -vw "$EXT_IF")

if [ -z "$AVAILABLE_IFS" ]; then
    echo "Error: No internal interface found. Please add a second network card to this VM."
    exit 1
fi

# Create an interactive menu for the user
PS3="Select the internal interface by entering its number: "
select INT_IF in $AVAILABLE_IFS; do
    if [ -n "$INT_IF" ]; then
        echo "--> Internal interface set to: $INT_IF"
        break
    else
        echo "Invalid selection. Please enter a valid number."
    fi
done

# 3. Prompt for the entire WireGuard config
echo ""
echo "============================================================"
echo "Please PASTE the entire content of your WireGuard .conf file."
echo "When you are done pasting, press 'Enter', then press 'Ctrl+D'."
echo "============================================================"
cat > /tmp/wg-temp.conf

if [ ! -s /tmp/wg-temp.conf ]; then
    echo "Error: No configuration was pasted."
    exit 1
fi

# 4. Extract universal variables (Endpoint, Port, DNS)
echo "Analyzing pasted configuration..."

# Extract DNS (Take the first one if multiple are provided)
DNS_SERVER=$(grep -i '^DNS' /tmp/wg-temp.conf | awk -F '=' '{print $2}' | tr -d ' ' | cut -d ',' -f 1)
if [ -z "$DNS_SERVER" ]; then
    echo "Warning: No DNS found in config. Using Cloudflare (1.1.1.1) as fallback."
    DNS_SERVER="1.1.1.1"
else
    echo "Detected DNS Server: $DNS_SERVER"
fi

# Extract Endpoint Host and Port
ENDPOINT_FULL=$(grep -i '^Endpoint' /tmp/wg-temp.conf | awk -F '=' '{print $2}' | tr -d ' ')
ENDPOINT_PORT=$(echo "$ENDPOINT_FULL" | awk -F ':' '{print $NF}')
ENDPOINT_HOST=$(echo "$ENDPOINT_FULL" | sed "s/:$ENDPOINT_PORT//")

if [ -z "$ENDPOINT_HOST" ] || [ -z "$ENDPOINT_PORT" ]; then
    echo "Error: Could not parse Endpoint Host/Port in the configuration."
    rm /tmp/wg-temp.conf
    exit 1
fi
echo "Detected VPN Port: $ENDPOINT_PORT"

# Resolve Domain to IP if necessary
if [[ $ENDPOINT_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    VPN_SERVER_IP=$ENDPOINT_HOST
    echo "Detected VPN Server IP: $VPN_SERVER_IP"
else
    echo "Domain detected ($ENDPOINT_HOST). Resolving to IP..."
    VPN_SERVER_IP=$(getent ahosts "$ENDPOINT_HOST" | awk '{ print $1 }' | head -n 1)
    
    if [ -z "$VPN_SERVER_IP" ]; then
        echo "Error: Could not resolve domain $ENDPOINT_HOST"
        rm /tmp/wg-temp.conf
        exit 1
    fi
    echo "Successfully resolved to IP: $VPN_SERVER_IP"
    sed -i "s/$ENDPOINT_HOST/$VPN_SERVER_IP/g" /tmp/wg-temp.conf
fi

# Move the finalized configuration
mkdir -p /etc/wireguard
mv /tmp/wg-temp.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# 5. Install required packages
echo "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wireguard iptables-persistent openresolv dnsmasq

# 6. Configure kernel routing
echo "Configuring kernel routing..."
cat <<EOF > /etc/sysctl.d/99-vpn-forwarding.conf
# Enable packet forwarding for IPv4
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-vpn-forwarding.conf

# 7. Configure the isolated network interface
echo "Setting up internal network interface ($INT_IF)..."
cat <<EOF > /etc/network/interfaces.d/$INT_IF
# Static configuration for the isolated network
allow-hotplug $INT_IF
iface $INT_IF inet static
    address 10.99.0.1
    netmask 255.255.255.0
EOF

# 8. Configure dnsmasq for DHCP (Universal DNS + No-Log)
echo "Configuring DHCP server..."
if [ -f /etc/dnsmasq.conf ]; then
    mv /etc/dnsmasq.conf /etc/dnsmasq.conf.backup
fi
cat <<EOF > /etc/dnsmasq.conf
interface=$INT_IF
port=0
dhcp-range=10.99.0.50,10.99.0.150,255.255.255.0,12h
dhcp-option=3,10.99.0.1
# Dynamically inject the VPN provider's DNS
dhcp-option=6,$DNS_SERVER

# Privacy: Disable DHCP logging completely
quiet-dhcp
log-facility=-
EOF

# 9. Create strict iptables rules (Dynamic Port)
echo "Writing strict Kill Switch rules..."
mkdir -p /etc/iptables
cat <<EOF > /etc/iptables/rules.v4
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT

*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

-A INPUT -i $INT_IF -j ACCEPT
-A OUTPUT -o $INT_IF -j ACCEPT

# Allow WireGuard traffic specifically on the dynamically detected port
-A INPUT -i $EXT_IF -p udp -m udp -s $VPN_SERVER_IP --sport $ENDPOINT_PORT -j ACCEPT
-A OUTPUT -o $EXT_IF -p udp -m udp -d $VPN_SERVER_IP --dport $ENDPOINT_PORT -j ACCEPT

-A INPUT -i wg0 -j ACCEPT
-A OUTPUT -o wg0 -j ACCEPT

-A FORWARD -i $INT_IF -o wg0 -j ACCEPT
-A FORWARD -i wg0 -o $INT_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o wg0 -j MASQUERADE
COMMIT
EOF

cat <<EOF > /etc/iptables/rules.v6
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
COMMIT
EOF

# 10. Implement Amnesia (RAM-only logging & history clearing)
echo "Implementing No-Log privacy settings..."

# Force systemd to store logs in volatile RAM only
mkdir -p /etc/systemd/journald.conf.d
cat <<EOF > /etc/systemd/journald.conf.d/99-volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=50M
EOF

# Prevent bash from saving command history permanently
ln -sf /dev/null /root/.bash_history
if ! grep -q "HISTFILE=/dev/null" /root/.bashrc; then
    echo "export HISTFILE=/dev/null" >> /root/.bashrc
fi

# Remove all old persistent journald logs from the disk
rm -rf /var/log/journal/* 2>/dev/null || true

# Empty all standard active log files
truncate -s 0 /var/log/*.log /var/log/syslog /var/log/auth.log /var/log/messages /var/log/daemon.log 2>/dev/null || true

# Permanently disable legacy login tracking by linking files to the void
rm -f /var/log/wtmp /var/log/lastlog /var/log/btmp 2>/dev/null || true
ln -s /dev/null /var/log/wtmp
ln -s /dev/null /var/log/lastlog
ln -s /dev/null /var/log/btmp

# Disable modern SQLite-based login tracking (Debian 13+ / Y2038 safe)
mkdir -p /var/lib/wtmpdb /var/lib/lastlog
rm -f /var/lib/wtmpdb/wtmp.db /var/lib/lastlog/lastlog2.db 2>/dev/null || true
ln -s /dev/null /var/lib/wtmpdb/wtmp.db
ln -s /dev/null /var/lib/lastlog/lastlog2.db

# Clean APT and dpkg history
truncate -s 0 /var/log/apt/* /var/log/dpkg.log /var/log/alternatives.log 2>/dev/null || true

# Completely remove Debian installer traces and answers
rm -rf /var/log/installer/* 2>/dev/null || true

# Clear downloaded packages cache
apt-get clean

# 11. Create the universal IP update helper script
echo "Creating the update-vpn-ip helper script..."
cat << 'EOF' > /usr/local/bin/update-vpn-ip
#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <new_ip_address>"
    exit 1
fi

NEW_IP=$1

if ! [[ $NEW_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid IP address format."
    exit 1
fi

WG_CONF="/etc/wireguard/wg0.conf"
IPTABLES_CONF="/etc/iptables/rules.v4"

# Dynamically find the old IP regardless of the port
OLD_ENDPOINT=$(grep -i '^Endpoint' $WG_CONF | awk -F '=' '{print $2}' | tr -d ' ')
OLD_IP=$(echo "$OLD_ENDPOINT" | sed 's/:.*//')

if [ -z "$OLD_IP" ]; then
    echo "Error: Could not find the old IP address in $WG_CONF."
    exit 1
fi

echo "Replacing old IP ($OLD_IP) with new IP ($NEW_IP)..."
sed -i "s/$OLD_IP/$NEW_IP/g" $WG_CONF
sed -i "s/$OLD_IP/$NEW_IP/g" $IPTABLES_CONF

echo "Reloading firewall rules..."
netfilter-persistent reload

echo "Restarting WireGuard..."
systemctl restart wg-quick@wg0

echo "Success! The VPN is now routing traffic through $NEW_IP."
systemctl status wg-quick@wg0 --no-pager
EOF

chmod +x /usr/local/bin/update-vpn-ip

# 12. Enable services to start on boot
echo "Enabling services..."
systemctl enable wg-quick@wg0
systemctl enable netfilter-persistent
systemctl enable dnsmasq

echo "=== Initialization complete! ==="
echo "The system will now reboot to cleanly apply all rules and clear RAM."
echo "Your SSH session will be disconnected."

# 13. Reboot the system
reboot