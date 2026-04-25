#!/bin/bash
# High Performance Subnet Flood Protection
# Blocks subnets (/24) if they exceed the connection threshold.

THRESHOLD=50  # Max connections per /24 subnet
BLOCK_TIME=3600 # Block for 1 hour
LOG_FILE="/var/log/anti_flood.log"
TMP_FILE="/tmp/conn_list.txt"

# Ensure log file exists
touch $LOG_FILE

# 1. Get current connections (excluding localhost and purely internal IPs)
netstat -ntu | awk '{print $5}' | cut -d: -f1 | grep -vE '127.0.0.1|0.0.0.0' | grep -v '^$' > $TMP_FILE

# 2. Extract subnets (/24) and count connections
SUBNETS=$(cat $TMP_FILE | cut -d. -f1-3 | sort | uniq -c | sort -nr)

# 3. Analyze and block
while read -r count subnet; do
    if [ "$count" -gt "$THRESHOLD" ]; then
        # Check if already blocked to avoid redundant rules
        if ! iptables -L INPUT -v -n | grep -q "$subnet.0/24"; then
            echo "$(date +"%Y-%m-%d %T") - BLOCKING subnet $subnet.0/24 ($count connections detected)" >> $LOG_FILE
            iptables -I INPUT -s "$subnet.0/24" -j DROP
            
            # Schedule unblock
            (sleep $BLOCK_TIME && iptables -D INPUT -s "$subnet.0/24" -j DROP && echo "$(date +"%Y-%m-%d %T") - UNBLOCKED subnet $subnet.0/24" >> $LOG_FILE) &
        fi
    fi
done <<< "$SUBNETS"

rm -f $TMP_FILE
