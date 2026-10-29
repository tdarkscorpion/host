
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
