#!/bin/bash
# Dynamic Port Unblocker Utility
# Usage: ./unblock_port.sh 8888

if [ -z "$1" ]; then
    echo "Usage: ./unblock_port.sh <port_number>"
    exit 1
fi

PORT=$1

# Core ports that should NEVER be blocked
PROHIBITED_PORTS=(22 80 443)

if [[ " ${PROHIBITED_PORTS[@]} " =~ " ${PORT} " ]]; then
    echo "Port $PORT is a core system port and is already handled/protected."
    exit 0
fi

echo "Unblocking port $PORT..."

# Detect OS and Firewall Tool
if which iptables > /dev/null; then
    iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
    # Persist for Ubuntu
    if [ -f /etc/os-release ] && grep -q "ubuntu" /etc/os-release; then
        netfilter-persistent save
    fi
fi

if which firewall-cmd > /dev/null; then
    firewall-cmd --permanent --add-port=$PORT/tcp
    firewall-cmd --reload
fi

if which ufw > /dev/null; then
    ufw allow $PORT/tcp
fi

echo "Port $PORT has been successfully unblocked."
