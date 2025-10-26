#!/bin/bash

# Webtop Ubuntu Desktop Installation Script
# Supports Iran/International locations and IP/Domain access with SSL

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Webtop Ubuntu Desktop Installation Script    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""

# Ask for location selection
echo -e "${YELLOW}Select your location:${NC}"
echo "1) Iran (uses ArvanCloud Docker mirror)"
echo "2) International (direct Docker Hub access)"
read -p "Enter your choice (1 or 2): " LOCATION_CHOICE

# Ask for access method
echo ""
echo -e "${YELLOW}Select access method:${NC}"
echo "1) IP address (HTTP - Port 6901)"
echo "2) Domain name (HTTPS with SSL certificate)"
read -p "Enter your choice (1 or 2): " ACCESS_CHOICE

# If domain is selected, ask for domain name
if [ "$ACCESS_CHOICE" = "2" ]; then
    echo ""
    read -p "Enter your domain name (e.g., ubuntu.example.com): " DOMAIN_NAME
    echo ""
    echo -e "${YELLOW}Important: Make sure your domain DNS is already pointing to this server IP!${NC}"
    read -p "Domain DNS is configured and pointing here? (yes/no): " DNS_CONFIRM
    if [ "$DNS_CONFIRM" != "yes" ]; then
        echo -e "${RED}Please configure your DNS first, then run this script again.${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}Starting installation...${NC}"
echo ""

# Configure ArvanCloud mirror for Iran
if [ "$LOCATION_CHOICE" = "1" ]; then
    echo -e "${YELLOW}Configuring ArvanCloud Docker mirror for Iran...${NC}"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["https://docker.arvancloud.ir"]
}
EOF
    echo -e "${GREEN}✓ ArvanCloud mirror configured${NC}"
fi

# Update system and install dependencies
echo -e "${YELLOW}Updating system packages...${NC}"
apt update -qq
apt install -y curl wget git openssl screen > /dev/null 2>&1
echo -e "${GREEN}✓ System packages updated${NC}"

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Installing Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh > /dev/null 2>&1
    rm get-docker.sh
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker
    echo -e "${GREEN}✓ Docker installed successfully${NC}"
else
    echo -e "${GREEN}✓ Docker already installed${NC}"
    # Restart Docker if ArvanCloud mirror was configured
    if [ "$LOCATION_CHOICE" = "1" ]; then
        systemctl restart docker
        echo -e "${GREEN}✓ Docker restarted with ArvanCloud mirror${NC}"
    fi
fi

# Generate random password
WEBTOP_PASSWORD=$(openssl rand -base64 18)
echo "$WEBTOP_PASSWORD" > /root/webtop_password.txt
echo -e "${GREEN}✓ Password generated and saved to /root/webtop_password.txt${NC}"

# Create docker-compose.yml (same config for both IP and Domain)
echo -e "${YELLOW}Creating Docker Compose configuration...${NC}"
cat > /root/docker-compose.yml <<EOF
services:
  webtop:
    image: lscr.io/linuxserver/webtop:ubuntu-xfce
    container_name: webtop-desktop
    security_opt:
      - seccomp:unconfined
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Tehran
      - CUSTOM_USER=admin
      - PASSWORD=${WEBTOP_PASSWORD}
    volumes:
      - /root/webtop-data:/config
    ports:
      - 127.0.0.1:3000:3001
    shm_size: "1gb"
    restart: unless-stopped
EOF

echo -e "${GREEN}✓ Docker Compose file created${NC}"

# Pull Docker image in background using screen
echo -e "${YELLOW}Downloading Webtop Docker image in background...${NC}"
echo -e "${YELLOW}This may take a few minutes depending on your connection speed.${NC}"

# Start download in screen session
screen -dmS webtop-download bash -c "docker compose -f /root/docker-compose.yml pull"

# Show download progress with spinner
spin='-\|/'
i=0
while screen -list | grep -q webtop-download; do
    i=$(( (i+1) %4 ))
    printf "\r${YELLOW}Downloading... ${spin:$i:1}${NC}"
    sleep 0.2
done

echo -e "\r${GREEN}✓ Docker image downloaded successfully${NC}"

# Install Nginx for both IP and Domain access
echo -e "${YELLOW}Installing Nginx for reverse proxy...${NC}"
apt install -y nginx > /dev/null 2>&1
echo -e "${GREEN}✓ Nginx installed${NC}"

# Start container first
echo -e "${YELLOW}Starting Webtop container...${NC}"
cd /root && docker compose up -d
echo -e "${GREEN}✓ Webtop container started${NC}"

# Wait for container to be ready
echo -e "${YELLOW}Waiting for container to initialize...${NC}"
sleep 10

# Configure SSL based on access method
if [ "$ACCESS_CHOICE" = "2" ]; then
    # Domain access - Let's Encrypt SSL
    echo -e "${YELLOW}Installing Certbot for Let's Encrypt SSL...${NC}"
    apt install -y certbot python3-certbot-nginx > /dev/null 2>&1
    echo -e "${GREEN}✓ Certbot installed${NC}"
    
    echo -e "${YELLOW}Obtaining SSL certificate from Let's Encrypt...${NC}"
    # Stop nginx temporarily for certbot standalone mode
    systemctl stop nginx
    certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email
    echo -e "${GREEN}✓ SSL certificate obtained${NC}"
    
    # Create Nginx configuration for reverse proxy
    echo -e "${YELLOW}Configuring Nginx reverse proxy with Let's Encrypt SSL...${NC}"
    cat > /etc/nginx/sites-available/webtop <<EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN_NAME;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass https://127.0.0.1:3000;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
EOF

    # Enable site and remove default
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/webtop /etc/nginx/sites-enabled/
    
    # Test and restart Nginx
    nginx -t > /dev/null 2>&1
    systemctl restart nginx
    echo -e "${GREEN}✓ Nginx configured with Let's Encrypt SSL${NC}"
    
else
    # IP access - Self-Signed SSL
    echo -e "${YELLOW}Generating self-signed SSL certificate for IP access...${NC}"
    
    # Create directory for SSL certificates
    mkdir -p /etc/nginx/ssl
    
    # Generate self-signed certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/webtop.key \
        -out /etc/nginx/ssl/webtop.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=$(curl -s ifconfig.me)" > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Self-signed SSL certificate generated${NC}"
    
    # Create Nginx configuration for IP access with self-signed SSL
    echo -e "${YELLOW}Configuring Nginx reverse proxy with self-signed SSL...${NC}"
    cat > /etc/nginx/sites-available/webtop <<EOF
server {
    listen 80;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    
    ssl_certificate /etc/nginx/ssl/webtop.crt;
    ssl_certificate_key /etc/nginx/ssl/webtop.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass https://127.0.0.1:3000;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
EOF

    # Enable site and remove default
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/webtop /etc/nginx/sites-enabled/
    
    # Test and restart Nginx
    nginx -t > /dev/null 2>&1
    systemctl restart nginx
    echo -e "${GREEN}✓ Nginx configured with self-signed SSL${NC}"
fi

# Save access information
if [ "$ACCESS_CHOICE" = "1" ]; then
    SERVER_IP=$(curl -s ifconfig.me)
    cat > /root/webtop-info.txt <<EOF
╔═══════════════════════════════════════════════════╗
║        Webtop Ubuntu Desktop Access Info          ║
╚═══════════════════════════════════════════════════╝

Access URL: https://$SERVER_IP
Username: admin
Password: $WEBTOP_PASSWORD

SSL Certificate: Self-Signed (Browser will show security warning)
Certificate Location: /etc/nginx/ssl/

IMPORTANT: Your browser will show a security warning because 
this is a self-signed certificate. This is normal for IP access.
Click "Advanced" and "Proceed" to continue.

Notes:
- Password is saved in: /root/webtop_password.txt
- Data directory: /root/webtop-data
- Container name: webtop-desktop
- Nginx config: /etc/nginx/sites-available/webtop

Useful Commands:
- Check status: docker ps
- View logs: docker logs webtop-desktop
- Restart container: docker restart webtop-desktop
- Restart nginx: systemctl restart nginx
EOF
else
    cat > /root/webtop-info.txt <<EOF
╔═══════════════════════════════════════════════════╗
║        Webtop Ubuntu Desktop Access Info          ║
╚═══════════════════════════════════════════════════╝

Access URL: https://$DOMAIN_NAME
Username: admin
Password: $WEBTOP_PASSWORD

SSL Certificate: Let's Encrypt (Valid for 90 days)
Certificate Location: /etc/letsencrypt/live/$DOMAIN_NAME/

Notes:
- Password is saved in: /root/webtop_password.txt
- Data directory: /root/webtop-data
- Container name: webtop-desktop
- Nginx config: /etc/nginx/sites-available/webtop

Useful Commands:
- Check status: docker ps
- View logs: docker logs webtop-desktop
- Restart container: docker restart webtop-desktop
- Restart nginx: systemctl restart nginx
- Renew SSL: certbot renew

SSL Certificate Auto-Renewal:
- Certbot automatically renews certificates
- Check renewal: certbot renew --dry-run
EOF
fi

# Display final information
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Installation Completed Successfully!     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
echo ""
cat /root/webtop-info.txt
echo ""
echo -e "${YELLOW}Access information saved to: /root/webtop-info.txt${NC}"
echo ""
