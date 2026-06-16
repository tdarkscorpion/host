#!/bin/bash
# Firewall Synchronization Setup Script
# Configures ipset and iptables to block game ports by default
# Deploys the Python daemon to whitelist IPs dynamically from the database

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

echo "Installing dependencies..."
# Determine OS and install ipset + python mysql driver
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        apt-get update
        apt-get install -y ipset python3 python3-pip python3-pymysql iptables-persistent
    elif [[ "$ID" == "centos" || "$ID" == "rhel" ]]; then
        yum install -y ipset python3 python3-pip iptables-services
        pip3 install pymysql
    fi
fi

# 1. Create the IPSET
echo "Creating ipset 'game_whitelist'..."
ipset create game_whitelist hash:ip timeout 28800 -exist

# 2. Configure iptables for the Game Port (Default: 5900)
# Make sure we don't duplicate rules if run multiple times
GAME_PORT=5900

echo "Configuring iptables for port $GAME_PORT..."
# Remove any existing rules for port 5900 to ensure clean slate
iptables -D INPUT -p tcp --dport $GAME_PORT -m set --match-set game_whitelist src -j ACCEPT 2>/dev/null
iptables -D INPUT -p tcp --dport $GAME_PORT -j DROP 2>/dev/null

# Insert rule to ALLOW from whitelisted IPs
iptables -A INPUT -p tcp --dport $GAME_PORT -m set --match-set game_whitelist src -j ACCEPT

# Insert rule to DROP all other traffic to port 5900
iptables -A INPUT -p tcp --dport $GAME_PORT -j DROP

# Save iptables depending on OS
if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
    netfilter-persistent save
elif [[ "$ID" == "centos" || "$ID" == "rhel" ]]; then
    service iptables save
fi

# 3. Deploy the Daemon
echo "Deploying the synchronization daemon..."
cp ./firewall_sync.py /usr/local/bin/firewall_sync.py
chmod +x /usr/local/bin/firewall_sync.py

# Grab DB_PASS from previous installation checkpoint if it exists
DB_PASS="talisman_pwd"
if [ -f /tmp/.install_checkpoints/credentials ]; then
    source /tmp/.install_checkpoints/credentials
fi

cp ./game-firewall-sync.service /etc/systemd/system/game-firewall-sync.service
# Inject password into service file
sed -i "s/Environment=\"DB_PASSWORD=.*\"/Environment=\"DB_PASSWORD=$DB_PASS\"/g" /etc/systemd/system/game-firewall-sync.service

systemctl daemon-reload
systemctl enable game-firewall-sync.service
systemctl restart game-firewall-sync.service

echo "==========================================================="
echo "Firewall synchronization setup complete!"
echo "Game port $GAME_PORT is now protected by default."
echo "Only IPs in 'db_valid_ip' will be granted access."
echo "Check daemon status with: systemctl status game-firewall-sync"
echo "==========================================================="
