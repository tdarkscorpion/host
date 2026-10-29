#!/bin/bash
# Universal Game Server Installer (Ubuntu & CentOS)
# Features: Resumable, Security hardened, Self-configuring.

LOG_FILE="/var/log/server_installer.log"
CP_DIR="/tmp/.install_checkpoints"
mkdir -p $CP_DIR

log() { echo -e "\e[32m[INSTALLER] $1\e[0m" | tee -a $LOG_FILE; }
error() { echo -e "\e[31m[ERROR] $1\e[0m" | tee -a $LOG_FILE; exit 1; }

# --- INITIAL CHECKS ---
if [[ $EUID -ne 0 ]]; then error "This script must be run as root (sudo)."; fi

# --- OS DETECTION ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    error "Unsupported Operating System."
fi

log "Detected OS: $OS $VER"

# --- INTERACTIVE SETUP ---
if [ -f "$CP_DIR/credentials" ]; then
    source "$CP_DIR/credentials"
    # Validate if credentials are sane (not empty and not garbage from a failed piped run)
    if [[ -z "$DB_PASS" || "$AUTH_DOMAIN" == *"STEP 1"* ]]; then
        rm "$CP_DIR/credentials"
        log "Previous credentials found but appear invalid. Restarting setup..."
    fi
fi

if [ ! -f "$CP_DIR/credentials" ]; then
    echo "==============================================="
    echo "       GAME SERVER INSTALLATION START          "
    echo "==============================================="
    # Use /dev/tty to ensure input works even when piped from curl
    while [[ -z "$DB_PASS" ]]; do
        read -p "Enter MySQL Root Password to set: " DB_PASS </dev/tty
    done
    while [[ -z "$AUTH_DOMAIN" ]]; do
        read -p "Enter authorized domain (e.g. localhost): " AUTH_DOMAIN </dev/tty
    done
    while [[ -z "$ENABLE_FIREWALL" ]]; do
        read -p "Do you want to enable the firewall and Anti-DDoS? (y/n): " ENABLE_FIREWALL </dev/tty
    done
    
    echo "DB_PASS=\"$DB_PASS\"" > "$CP_DIR/credentials"
    echo "AUTH_DOMAIN=\"$AUTH_DOMAIN\"" >> "$CP_DIR/credentials"
    echo "ENABLE_FIREWALL=\"$ENABLE_FIREWALL\"" >> "$CP_DIR/credentials"
    
    # Save MySQL password to /root
    echo "$DB_PASS" > /root/mysql_passwd
    chmod 600 /root/mysql_passwd
else
    log "Resuming with previous credentials..."
fi

# --- STEP 1: SYSTEM UPDATES & DEPENDENCIES ---
if [ ! -f "$CP_DIR/step1" ]; then
    log "Step 1: Installing dependencies..."
    if [ "$OS" == "ubuntu" ]; then
        apt-get update && apt-get install -y software-properties-common curl git unzip wget iptables-persistent fail2ban p7zip-full default-mysql-client
        add-apt-repository -y ppa:ondrej/php
        apt-get update
    else
        yum install -y epel-release yum-utils
        yum groupinstall -y "Development Tools"
        yum install -y curl git unzip wget iptables-services fail2ban p7zip mariadb
    fi
    touch "$CP_DIR/step1"
fi

# --- STEP 1.5: LEGACY LIBRARIES ---
if [ ! -f "$CP_DIR/step1_5" ]; then
    log "Step 1.5: Installing Legacy Libraries..."
    if [ "$OS" == "ubuntu" ]; then
        dpkg --add-architecture i386
        apt-get update
        apt-get install -y lib32stdc++6
        # Download and install the specific deb if not present
        if [ ! -f "libmysqlclient15off_5.1.30really5.0.75-0ubuntu10.5_i386.deb" ]; then
            wget -q https://raw.githubusercontent.com/tdarkscorpion/letestfile/master/libmysqlclient15off_5.1.30really5.0.75-0ubuntu10.5_i386.deb
        fi
        dpkg -i libmysqlclient15off_5.1.30really5.0.75-0ubuntu10.5_i386.deb || apt-get install -f -y
    else
        # CentOS
        yum install -y libstdc++.i686
        # Download and install the specific rpm if not present
        if [ ! -f "mysqlclient15-5.0.67-1.el5.remi.i386.rpm" ]; then
            wget -q https://raw.githubusercontent.com/tdarkscorpion/letestfile/master/mysqlclient15-5.0.67-1.el5.remi.i386.rpm
        fi
        yum install -y mysqlclient15-5.0.67-1.el5.remi.i386.rpm
