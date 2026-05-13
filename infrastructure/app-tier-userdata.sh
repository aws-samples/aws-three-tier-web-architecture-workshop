#!/bin/bash
# App Tier EC2 user-data — Amazon Linux 2
# Installs Node 16 + PM2, deploys Node.js API, writes DbConfig.
# Run as root at first boot.

set -euxo pipefail

# ── Variables (set before launch or via SSM Parameter Store) ──────────────────
S3_BUCKET="${S3_BUCKET:-YOUR-S3-BUCKET-NAME}"
DB_HOST="${DB_HOST:-REPLACE-WITH-AURORA-WRITER-ENDPOINT}"
DB_USER="${DB_USER:-admin}"
DB_PWD="${DB_PWD:-REPLACE-WITH-DB-PASSWORD}"
DB_DATABASE="${DB_DATABASE:-webappdb}"

# ── System update ─────────────────────────────────────────────────────────────
yum update -y

# ── Node.js 16 ────────────────────────────────────────────────────────────────
curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
yum install -y nodejs

# ── PM2 (process manager) ─────────────────────────────────────────────────────
npm install -g pm2
pm2 startup systemd -u ec2-user --hp /home/ec2-user
systemctl enable pm2-ec2-user

# ── Deploy app from S3 ────────────────────────────────────────────────────────
mkdir -p /home/ec2-user/app-tier
aws s3 cp s3://${S3_BUCKET}/app-tier /home/ec2-user/app-tier --recursive

# ── Write database config ─────────────────────────────────────────────────────
cat > /home/ec2-user/app-tier/DbConfig.js <<DBCONF
module.exports = Object.freeze({
    DB_HOST : '${DB_HOST}',
    DB_USER : '${DB_USER}',
    DB_PWD  : '${DB_PWD}',
    DB_DATABASE : '${DB_DATABASE}'
});
DBCONF

# ── Install dependencies and start ────────────────────────────────────────────
cd /home/ec2-user/app-tier
npm install

chown -R ec2-user:ec2-user /home/ec2-user/app-tier

sudo -u ec2-user pm2 start index.js
sudo -u ec2-user pm2 save
