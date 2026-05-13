#!/bin/bash
# Web Tier EC2 user-data — Amazon Linux 2
# Installs Nginx + Node 16, deploys React build, configures reverse proxy.
# Run as root at first boot.

set -euxo pipefail

# ── Variables (set before launch or via SSM Parameter Store) ──────────────────
S3_BUCKET="${S3_BUCKET:-YOUR-S3-BUCKET-NAME}"
INTERNAL_LB_DNS="${INTERNAL_LB_DNS:-REPLACE-WITH-INTERNAL-LB-DNS}"

# ── System update ─────────────────────────────────────────────────────────────
yum update -y

# ── Node.js 16 ────────────────────────────────────────────────────────────────
curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
yum install -y nodejs

# ── Nginx ─────────────────────────────────────────────────────────────────────
yum install -y nginx
systemctl enable nginx

# ── Deploy React app from S3 ─────────────────────────────────────────────────
mkdir -p /home/ec2-user/web-tier
aws s3 cp s3://${S3_BUCKET}/web-tier /home/ec2-user/web-tier --recursive
cd /home/ec2-user/web-tier
npm install
npm run build

# ── Nginx config ─────────────────────────────────────────────────────────────
cat > /etc/nginx/nginx.conf <<NGINX
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events { worker_connections 1024; }

http {
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 65; types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        listen [::]:80;
        server_name _;

        location /health {
            default_type text/html;
            return 200 "<!DOCTYPE html><p>Web Tier Health Check</p>\n";
        }

        location / {
            root    /home/ec2-user/web-tier/build;
            index   index.html index.htm;
            try_files \$uri /index.html;
        }

        location /api/ {
            proxy_pass http://${INTERNAL_LB_DNS}:80/;
        }
    }
}
NGINX

systemctl start nginx

# ── Fix permissions ───────────────────────────────────────────────────────────
chown -R ec2-user:ec2-user /home/ec2-user/web-tier
chmod -R 755 /home/ec2-user/web-tier/build
