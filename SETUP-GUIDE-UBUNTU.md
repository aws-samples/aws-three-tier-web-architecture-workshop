# Three-Tier AWS Architecture — Ubuntu Instance Setup Guide

Same architecture, Ubuntu flavour.  
All commands run as the default `ubuntu` user unless `sudo` is shown.  
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

## Recommended Ubuntu AMI

Use **Ubuntu Server 22.04 LTS (HVM), SSD Volume Type** — search for it in the
EC2 Launch Wizard.  
Architecture: `x86_64` | Instance type: `t2.micro` (or `t3.micro`)

Resolve the latest AMI ID for your region via AWS CLI:

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text \
  --region <YOUR_REGION>
```

---

## Prerequisites (all tiers)

- Instances launched with Ubuntu 22.04 LTS
- Security groups configured:
  - Web Tier SG: inbound **80** from External ALB SG
  - App Tier SG: inbound **4000** from Internal ALB SG
  - DB SG: inbound **3306** from App Tier SG only
- EC2 instance role has `AmazonS3ReadOnlyAccess` and `AmazonSSMManagedInstanceCore`
- SSH user is `ubuntu` (not `ec2-user`)

---

## Part 1 — Database Tier

### Option A: Amazon Aurora MySQL (RDS) — Recommended

Steps are identical to the Amazon Linux guide — Aurora is a managed service,
no OS differences apply.

1. **RDS Console → Create database**
2. Engine: **Aurora (MySQL Compatible)** `8.0`
3. Template: Dev/Test or Production
4. Cluster identifier: `three-tier-aurora-cluster`
5. Master username: `admin` | Master password: set and note it down
6. Instance class: `db.t3.micro`
7. Multi-AZ: **Enable**
8. VPC: workshop VPC | Subnets: private subnets only | Public access: **No**
9. Security group: DB security group (inbound 3306 from App Tier SG)
10. Additional config → Initial database name: `webappdb`
11. **Create database** (takes ~5 min)

Note down the **writer endpoint** once the cluster is available.

**Create the transactions table** (run from App Tier after Node.js is ready):

```bash
sudo apt install -y mysql-client

mysql -h <writer-endpoint> -u admin -p webappdb <<SQL
CREATE TABLE IF NOT EXISTS transactions (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    amount      DECIMAL(10,2) NOT NULL,
    description VARCHAR(255)  NOT NULL
);
SQL
```

---

### Option B: MySQL 8.0 on Ubuntu EC2

SSH into your **DB Tier Ubuntu EC2** and run:

```bash
# Update package list
sudo apt update && sudo apt upgrade -y

# Install MySQL 8.0
sudo apt install -y mysql-server

# Secure the installation (set root password, remove test DB, disallow remote root)
sudo mysql_secure_installation
```

```bash
# Log in as root (Ubuntu MySQL installs with auth_socket by default)
sudo mysql

-- Create app database and user
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

Allow MySQL to accept connections from the App Tier (default Ubuntu MySQL binds to 127.0.0.1 only):

```bash
sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
# Change:  bind-address = 127.0.0.1
# To:      bind-address = 0.0.0.0

sudo systemctl restart mysql
sudo systemctl enable mysql
```

> Note down this instance's **private IP** — it will be your `DB_HOST` in `DbConfig.js`.

---

## Part 2 — App Tier Instance

SSH into your **App Tier Ubuntu EC2**.

### Step 1 — System update

```bash
sudo apt update && sudo apt upgrade -y
```

### Step 2 — Install Node.js 16

```bash
curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt install -y nodejs
node -v   # v16.x.x
npm -v
```

### Step 3 — Install Git

```bash
sudo apt install -y git
```

### Step 4 — Install PM2

```bash
sudo npm install -g pm2
```

### Step 5 — Clone the repository

```bash
cd /home/ubuntu
git clone https://github.com/Asadkhanrtx/aws-three-tier-web-architecture-workshop.git
cd aws-three-tier-web-architecture-workshop
```

### Step 6 — Configure the database connection  ⚠️ CODE CHANGE REQUIRED

```bash
nano application-code/app-tier/DbConfig.js
```

```js
// BEFORE (do not leave empty strings)
module.exports = Object.freeze({
    DB_HOST : '',
    DB_USER : '',
    DB_PWD : '',
    DB_DATABASE : ''
});
```

```js
// AFTER — fill in your actual values
module.exports = Object.freeze({
    DB_HOST : 'three-tier-aurora-cluster.cluster-xxxx.<region>.rds.amazonaws.com',
    // If using EC2 MySQL: DB_HOST : '10.0.x.x'  (private IP of DB EC2)
    DB_USER : 'admin',
    DB_PWD  : 'YourStrongPassword123!',
    DB_DATABASE : 'webappdb'
});
```

Save: `Ctrl+O` → `Enter` → `Ctrl+X`

### Step 7 — Install dependencies and start the app

```bash
cd /home/ubuntu/aws-three-tier-web-architecture-workshop/application-code/app-tier
npm install
pm2 start index.js --name "app-tier"
pm2 save
```

Enable PM2 on reboot:

```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u ubuntu --hp /home/ubuntu
# Copy and run the command that pm2 prints out, then:
pm2 save
```

### Step 8 — Verify the app tier

```bash
pm2 status

# Health check
curl http://localhost:4000/health
# Expected: "This is the health check"

# DB connection check
curl http://localhost:4000/transaction
# Expected: {"result":[]}
```

If you see a MySQL connection error, check:
- `DbConfig.js` has the correct endpoint/IP and credentials
- DB security group allows port 3306 from App Tier SG
- For EC2 MySQL: confirm `bind-address = 0.0.0.0` and MySQL is running

---

## Part 3 — Web Tier Instance

SSH into your **Web Tier Ubuntu EC2**.

### Step 1 — System update

```bash
sudo apt update && sudo apt upgrade -y
```

### Step 2 — Install Node.js 16 and Nginx

```bash
# Node.js 16
curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt install -y nodejs

# Nginx
sudo apt install -y nginx git

node -v
nginx -v
```

### Step 3 — Clone the repository

```bash
cd /home/ubuntu
git clone https://github.com/Asadkhanrtx/aws-three-tier-web-architecture-workshop.git
cd aws-three-tier-web-architecture-workshop
```

### Step 4 — Build the React app

```bash
cd /home/ubuntu/aws-three-tier-web-architecture-workshop/application-code/web-tier
npm install
npm run build
```

Build output lands at:
`/home/ubuntu/aws-three-tier-web-architecture-workshop/application-code/web-tier/build/`

### Step 5 — Configure Nginx  ⚠️ CODE CHANGE REQUIRED

```bash
sudo nano /etc/nginx/sites-available/default
```

Replace the entire file with:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    # Health check for External ALB
    location /health {
        default_type text/html;
        return 200 "<!DOCTYPE html><p>Web Tier Health Check</p>\n";
    }

    # Serve React SPA
    location / {
        root  /home/ubuntu/aws-three-tier-web-architecture-workshop/application-code/web-tier/build;
        index index.html index.htm;
        try_files $uri /index.html;
    }

    # Proxy API calls → Internal ALB → App Tier
    location /api/ {
        proxy_pass http://REPLACE-WITH-INTERNAL-LB-DNS:80/;
    }
}
```

> **Where to find the Internal ALB DNS:**  
> AWS Console → EC2 → Load Balancers → select Internal ALB → copy DNS name.  
> Example: `internal-three-tier-internal-alb-xxxx.us-east-1.elb.amazonaws.com`

Remove the default symlink and re-enable:

```bash
sudo rm /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
```

Fix permissions so Nginx can read the build folder:

```bash
sudo chmod 755 /home/ubuntu
sudo chmod -R 755 /home/ubuntu/aws-three-tier-web-architecture-workshop/application-code/web-tier/build
```

### Step 6 — Start Nginx

```bash
sudo nginx -t                    # must print "syntax is ok"
sudo systemctl restart nginx
sudo systemctl enable nginx
```

### Step 7 — Verify the web tier

```bash
# Health check
curl http://localhost/health
# Expected: <!DOCTYPE html><p>Web Tier Health Check</p>

# API proxy test (Internal LB must be up and App Tier must be running)
curl http://localhost/api/health
# Expected: "This is the health check"
```

Open the instance's public IP in a browser — React app should load.  
Go to the **DB Demo page** (hamburger menu → DB Demo) and add a transaction to
confirm full end-to-end connectivity.

---

## Part 4 — Summary of All Code Changes

| File | What to change | Instance |
|---|---|---|
| `application-code/app-tier/DbConfig.js` | `DB_HOST`, `DB_USER`, `DB_PWD`, `DB_DATABASE` | App Tier EC2 |
| `/etc/nginx/sites-available/default` | Replace `REPLACE-WITH-INTERNAL-LB-DNS` with actual Internal ALB DNS | Web Tier EC2 |

No changes needed in React source code — it uses relative `/api/` paths that Nginx proxies automatically.

---

## Part 5 — End-to-End Test Before Creating AMIs

Run these in order:

```bash
# 1. On App Tier — DB connection
curl http://localhost:4000/transaction
# {"result":[]}

# 2. On Web Tier — proxy through Internal LB to App Tier
curl http://localhost/api/health
# "This is the health check"

# 3. On Web Tier — full stack (web → internal LB → app → DB)
curl http://localhost/api/transaction
# {"result":[]}
```

All three must succeed before you create AMIs.

---

## Part 6 — Create AMIs for Auto Scaling

**AWS Console → EC2 → Instances → select instance → Actions → Image and templates → Create image**

| Tier | Suggested AMI name | What's captured |
|---|---|---|
| App Tier | `ubuntu-app-tier-ami-v1` | Node 16, PM2, cloned repo, filled `DbConfig.js`, pm2 startup configured |
| Web Tier | `ubuntu-web-tier-ami-v1` | Node 16, Nginx, React build, nginx config with Internal LB DNS |

> Aurora DB Tier has no AMI — it is a managed RDS service.

**After AMI creation (~5 min):**

1. **Launch Template** — use the new AMI, instance type `t2.micro`, correct SG and IAM role
2. **Auto Scaling Group** — attach Launch Template, set min/max/desired, link to ALB target group

---

## Quick Reference — Ports and Services

| Component | Port | Health check path | Ubuntu service |
|---|---|---|---|
| Nginx (Web Tier) | 80 | `GET /health` | `nginx` |
| Node.js (App Tier) | 4000 | `GET /health` | `pm2` (app-tier process) |
| MySQL (EC2 DB) | 3306 | — | `mysql` |
| Aurora (RDS) | 3306 | — | managed |

Useful service commands on Ubuntu:

```bash
# Nginx
sudo systemctl status nginx
sudo systemctl restart nginx
sudo tail -f /var/log/nginx/error.log

# PM2 / Node.js
pm2 status
pm2 logs app-tier --lines 50
pm2 restart app-tier

# MySQL (EC2 option)
sudo systemctl status mysql
sudo journalctl -u mysql -n 50
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl /api/health` returns 502 Bad Gateway | Internal LB DNS wrong in nginx config, or App Tier not running | Check `/etc/nginx/sites-available/default` proxy_pass; run `pm2 status` on App Tier |
| PM2 logs show `ECONNREFUSED` or `ENOTFOUND` | Wrong `DB_HOST` in `DbConfig.js` | Verify Aurora writer endpoint or EC2 DB private IP |
| PM2 logs show `Access denied for user` | Wrong credentials in `DbConfig.js` | Re-check `DB_USER` and `DB_PWD` |
| Nginx returns 403 Forbidden | Build directory not readable by nginx | `sudo chmod 755 /home/ubuntu` and build folder |
| `sudo nginx -t` fails | Config syntax error | Re-check `sites-available/default`; look for missing semicolons |
| React app loads, DB Demo shows nothing | App Tier SG or Internal ALB not configured | Confirm Internal ALB target group shows App Tier as **healthy** |
| ASG instances fail health checks after launch | PM2 or Nginx not auto-starting | Confirm `pm2 startup` and `systemctl enable nginx` were run before AMI snapshot |
| EC2 MySQL refuses remote connections | bind-address still 127.0.0.1 | Set `bind-address = 0.0.0.0` in `/etc/mysql/mysql.conf.d/mysqld.cnf` and restart |

---

## Key Differences vs Amazon Linux 2

| Item | Amazon Linux 2 | Ubuntu 22.04 |
|---|---|---|
| Package manager | `yum` | `apt` |
| Default SSH user | `ec2-user` | `ubuntu` |
| Node.js setup script | `nodesource.com/setup_16.x \| bash -` | `nodesource.com/setup_16.x \| sudo -E bash -` |
| Nginx config location | `/etc/nginx/nginx.conf` | `/etc/nginx/sites-available/default` |
| Nginx sites-enabled | not used | `/etc/nginx/sites-enabled/` (symlink required) |
| MySQL package | `mysql-community-server` (via rpm) | `mysql-server` (via apt) |
| MySQL root login | `mysql -u root -p` | `sudo mysql` (auth_socket) |
| Home directory | `/home/ec2-user` | `/home/ubuntu` |
