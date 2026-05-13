# Three-Tier AWS Architecture — Complete Instance Setup Guide

This guide walks you through configuring each EC2 instance from scratch before
you create AMIs for your Auto Scaling Groups.  
Follow the order: **DB Tier → App Tier → Web Tier**.

---

## Architecture Connection Map

```
Internet
   │
   ▼
External ALB  (port 80, public subnets)
   │
   ▼
Web Tier EC2  (Nginx, port 80, public subnets)
   │  /api/* requests proxied
   ▼
Internal ALB  (port 80, private subnets)
   │
   ▼
App Tier EC2  (Node.js, port 4000, private subnets)
   │
   ▼
Aurora MySQL / EC2 MySQL  (port 3306, private subnets)
```

---

## Prerequisites (all tiers)

- All three instances are launched and running (Amazon Linux 2)
- Security groups are configured:
  - Web Tier SG: inbound 80 from External ALB SG
  - App Tier SG: inbound 4000 from Internal ALB SG
  - DB SG: inbound 3306 from App Tier SG only
- EC2 instance role has `AmazonS3ReadOnlyAccess` and `AmazonSSMManagedInstanceCore` attached
- You are SSH'd into each instance as `ec2-user`

---

## Part 1 — Database Tier

### Option A: Amazon Aurora MySQL (RDS) — Recommended

**In the RDS Console:**

1. Go to **RDS → Create database**
2. Choose **Standard Create**
3. Engine: **Aurora (MySQL Compatible)**, version `8.0`
4. Template: **Dev/Test** (or Production for HA)
5. DB cluster identifier: `three-tier-aurora-cluster`
6. Master username: `admin` (note this down)
7. Master password: set a strong password (note this down)
8. Instance class: `db.t3.micro`
9. Multi-AZ: **Enable** (creates one writer + one reader)
10. VPC: select your workshop VPC
11. Subnet group: select private subnets only
12. Public access: **No**
13. Security group: attach the DB security group (inbound 3306 from App Tier SG)
14. Additional config → Initial database name: `webappdb`
15. Click **Create database**

**After cluster is created (~5 min), note down:**
- Writer endpoint: `three-tier-aurora-cluster.cluster-xxxx.<region>.rds.amazonaws.com`
- Port: `3306`

**Create the transactions table** (run from your App Tier instance after Node.js is set up, or from any instance with MySQL client):

```sql
mysql -h <writer-endpoint> -u admin -p webappdb

CREATE TABLE IF NOT EXISTS transactions (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    amount      DECIMAL(10,2) NOT NULL,
    description VARCHAR(255)  NOT NULL
);

EXIT;
```

---

### Option B: MySQL on EC2 (if not using RDS)

SSH into your DB Tier EC2 instance and run:

```bash
# Update system
sudo yum update -y

# Install MySQL 8.0
sudo rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el7-5.noarch.rpm
sudo yum install -y mysql-community-server

# Start and enable MySQL
sudo systemctl start mysqld
sudo systemctl enable mysqld

# Get the temporary root password
sudo grep 'temporary password' /var/log/mysqld.log
```

```bash
# Secure the installation and set a new root password
sudo mysql_secure_installation
# Follow prompts: set new password, remove anonymous users, disallow remote root, remove test DB
```

```bash
# Log in as root
mysql -u root -p

# Create app database and user
CREATE DATABASE webappdb;
CREATE USER 'appuser'@'%' IDENTIFIED BY 'YourStrongPassword123!';
GRANT ALL PRIVILEGES ON webappdb.* TO 'appuser'@'%';
FLUSH PRIVILEGES;

USE webappdb;

CREATE TABLE IF NOT EXISTS transactions (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    amount      DECIMAL(10,2) NOT NULL,
    description VARCHAR(255)  NOT NULL
);

EXIT;
```

> Note down your EC2 DB instance's **private IP address** — this will be your `DB_HOST`.

---

## Part 2 — App Tier Instance

SSH into your **App Tier EC2** (private subnet, accessed via bastion or SSM Session Manager).

### Step 1 — Install Node.js 16

```bash
sudo yum update -y
curl -fsSL https://rpm.nodesource.com/setup_16.x | sudo bash -
sudo yum install -y nodejs
node -v   # should print v16.x.x
npm -v
```

### Step 2 — Install PM2

```bash
sudo npm install -g pm2
```

### Step 3 — Clone the repository

```bash
cd /home/ec2-user
git clone https://github.com/Asadkhanrtx/aws-three-tier-web-architecture-workshop.git
cd aws-three-tier-web-architecture-workshop
```

### Step 4 — Configure the database connection  ⚠️ CODE CHANGE REQUIRED

Open the database config file:

```bash
nano application-code/app-tier/DbConfig.js
```

Replace the empty strings with your actual values:

```js
// BEFORE (default — do not leave empty)
module.exports = Object.freeze({
    DB_HOST : '',
    DB_USER : '',
    DB_PWD : '',
    DB_DATABASE : ''
});
```

```js
// AFTER — fill in your values
module.exports = Object.freeze({
    DB_HOST : 'three-tier-aurora-cluster.cluster-xxxx.<region>.rds.amazonaws.com',
    // If using EC2 MySQL: DB_HOST : '10.0.x.x'  (private IP of DB instance)
    DB_USER : 'admin',
    DB_PWD  : 'YourStrongPassword123!',
    DB_DATABASE : 'webappdb'
});
```

Save and close (`Ctrl+O`, `Enter`, `Ctrl+X`).

### Step 5 — Install dependencies and start the app

```bash
cd /home/ec2-user/aws-three-tier-web-architecture-workshop/application-code/app-tier
npm install
pm2 start index.js --name "app-tier"
pm2 save
```

Enable PM2 to restart on reboot:

```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u ec2-user --hp /home/ec2-user
sudo systemctl enable pm2-ec2-user
```

### Step 6 — Verify the app tier is running

```bash
# Check PM2 status
pm2 status

# Test health endpoint locally
curl http://localhost:4000/health
# Expected response: "This is the health check"

# Test DB connection via transaction endpoint
curl http://localhost:4000/transaction
# Expected: {"result":[]}  or a list of transactions
```

If you see a MySQL connection error, double-check:
- `DbConfig.js` has the correct endpoint/IP and credentials
- DB security group allows port 3306 from this instance's security group
- Aurora cluster is in **Available** state

---

## Part 3 — Web Tier Instance

SSH into your **Web Tier EC2** (public subnet).

### Step 1 — Install Node.js 16 and Nginx

```bash
sudo yum update -y
curl -fsSL https://rpm.nodesource.com/setup_16.x | sudo bash -
sudo yum install -y nodejs nginx
node -v
```

### Step 2 — Clone the repository

```bash
cd /home/ec2-user
git clone https://github.com/Asadkhanrtx/aws-three-tier-web-architecture-workshop.git
cd aws-three-tier-web-architecture-workshop
```

### Step 3 — Build the React app

```bash
cd /home/ec2-user/aws-three-tier-web-architecture-workshop/application-code/web-tier
npm install
npm run build
```

This creates `/home/ec2-user/aws-three-tier-web-architecture-workshop/application-code/web-tier/build/`.

### Step 4 — Configure Nginx  ⚠️ CODE CHANGE REQUIRED

Open the nginx config:

```bash
sudo nano /etc/nginx/nginx.conf
```

Replace the entire content with the config below.  
**Replace `REPLACE-WITH-INTERNAL-LB-DNS` with your Internal ALB DNS name.**

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events { worker_connections 1024; }

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 65; types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        listen [::]:80;
        server_name _;

        # Health check for External ALB
        location /health {
            default_type text/html;
            return 200 "<!DOCTYPE html><p>Web Tier Health Check</p>\n";
        }

        # Serve React SPA
        location / {
            root    /home/ec2-user/aws-three-tier-web-architecture-workshop/application-code/web-tier/build;
            index   index.html index.htm;
            try_files $uri /index.html;
        }

        # Proxy API calls to Internal ALB → App Tier
        location /api/ {
            proxy_pass http://REPLACE-WITH-INTERNAL-LB-DNS:80/;
        }
    }
}
```

> **Where to find the Internal ALB DNS name:**  
> AWS Console → EC2 → Load Balancers → select your Internal ALB → copy the DNS name  
> It looks like: `internal-three-tier-internal-alb-xxxx.us-east-1.elb.amazonaws.com`

Fix nginx file permissions so it can read the React build:

```bash
sudo chmod 755 /home/ec2-user
sudo chmod -R 755 /home/ec2-user/aws-three-tier-web-architecture-workshop/application-code/web-tier/build
```

### Step 5 — Start Nginx

```bash
sudo nginx -t          # test config — must say "syntax is ok"
sudo systemctl start nginx
sudo systemctl enable nginx
```

### Step 6 — Verify the web tier is running

```bash
# Health check
curl http://localhost/health
# Expected: <!DOCTYPE html><p>Web Tier Health Check</p>

# Check if React build is served
curl -s http://localhost/ | head -5
# Expected: HTML content starting with <!DOCTYPE html>
```

Also open the instance's public IP in a browser — you should see the React app.

---

## Part 4 — Summary of All Code Changes

| File | Change | Where |
|---|---|---|
| `application-code/app-tier/DbConfig.js` | Fill `DB_HOST`, `DB_USER`, `DB_PWD`, `DB_DATABASE` | App Tier EC2 |
| `/etc/nginx/nginx.conf` | Replace `REPLACE-WITH-INTERNAL-LB-DNS` with Internal ALB DNS | Web Tier EC2 |

No changes are needed to the React frontend code — it uses relative `/api/` calls which Nginx proxies automatically.

---

## Part 5 — Test End-to-End Before Creating AMIs

1. **From Web Tier EC2**, test that the proxy reaches the app tier:
   ```bash
   curl http://localhost/api/health
   # Expected: "This is the health check"
   ```

2. **Open the web app in a browser** at the web tier's public IP.  
   Navigate to the **DB Demo page** (hamburger menu → DB Demo).  
   Add a transaction — if it saves and loads, all three tiers are connected.

3. **Check PM2 logs** on the App Tier for any DB errors:
   ```bash
   pm2 logs app-tier --lines 50
   ```

---

## Part 6 — Create AMIs for Auto Scaling

Once each instance is fully working, create an AMI from it:

**AWS Console → EC2 → Instances → select instance → Actions → Image and templates → Create image**

| Tier | AMI Name (suggestion) | What's baked in |
|---|---|---|
| App Tier | `app-tier-ami-v1` | Node 16, PM2, app code, `DbConfig.js` |
| Web Tier | `app-web-tier-ami-v1` | Node 16, Nginx, React build, nginx.conf with Internal LB DNS |

> The DB Tier (Aurora RDS) has no AMI — it is a managed service.

**After AMI is available (~5 min):**
1. Create a **Launch Template** using the AMI
2. Set instance type `t2.micro`, attach the correct security group and IAM role
3. Create an **Auto Scaling Group** using that Launch Template
4. Set min/max/desired capacity and attach to the corresponding ALB target group

---

## Quick Reference — Ports and Endpoints

| Component | Port | Protocol | Notes |
|---|---|---|---|
| External ALB | 80 | HTTP | Public-facing, routes to Web Tier |
| Web Tier (Nginx) | 80 | HTTP | Health check: `GET /health` |
| Internal ALB | 80 | HTTP | Private, routes to App Tier |
| App Tier (Node.js) | 4000 | HTTP | Health check: `GET /health` |
| Aurora MySQL / EC2 MySQL | 3306 | TCP | Accessible from App Tier SG only |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/api/health` returns 502 Bad Gateway | Internal LB DNS wrong in nginx.conf, or App Tier not running | Check nginx.conf proxy_pass value; run `pm2 status` on App Tier |
| App Tier `pm2 logs` shows `ECONNREFUSED` or `ENOTFOUND` | DB_HOST in DbConfig.js is wrong | Verify Aurora endpoint or EC2 DB private IP |
| App Tier `pm2 logs` shows `Access denied for user` | DB credentials wrong | Re-check DB_USER and DB_PWD in DbConfig.js |
| React app loads but DB Demo shows nothing | Internal ALB not yet configured, or App Tier SG blocks port 4000 | Confirm Internal ALB target group has App Tier registered and healthy |
| `sudo nginx -t` fails | Syntax error in nginx.conf | Check for missing semicolons; re-paste config from this guide |
| AMI instances in ASG fail health checks | app or nginx not started at boot | Ensure `pm2 startup` and `systemctl enable nginx` were run before AMI creation |
