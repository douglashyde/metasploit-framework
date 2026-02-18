#!/bin/bash
# Metasploit Framework - Full Dependency Installation Script
# Supports Ubuntu/Debian systems
# Usage: sudo ./scripts/setup/install_dependencies.sh

set -e

echo "[*] Metasploit Framework Dependency Installer"
echo "[*] ==========================================="

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "[-] This script must be run as root (use sudo)"
  exit 1
fi

MSF_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "[*] Metasploit root: $MSF_ROOT"

# -------------------------------------------------------
# 1. System packages
# -------------------------------------------------------
echo ""
echo "[*] Step 1/5: Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
  build-essential \
  autoconf \
  bison \
  git \
  curl \
  wget \
  ruby-dev \
  libpq-dev \
  libpcap-dev \
  libxml2-dev \
  libxslt1-dev \
  libsqlite3-dev \
  libssl-dev \
  libyaml-dev \
  libreadline-dev \
  libffi-dev \
  zlib1g-dev \
  postgresql \
  postgresql-client \
  nmap

echo "[+] System packages installed."

# -------------------------------------------------------
# 2. Bundler
# -------------------------------------------------------
echo ""
echo "[*] Step 2/5: Installing Bundler..."
if ! command -v bundle &> /dev/null; then
  gem install bundler
  echo "[+] Bundler installed."
else
  echo "[+] Bundler already installed: $(bundle --version)"
fi

# -------------------------------------------------------
# 3. Ruby gems
# -------------------------------------------------------
echo ""
echo "[*] Step 3/5: Installing Ruby gems via Bundler..."
cd "$MSF_ROOT"
bundle config set --local jobs "$(nproc)"
bundle install
echo "[+] All gems installed."

# -------------------------------------------------------
# 4. PostgreSQL database setup
# -------------------------------------------------------
echo ""
echo "[*] Step 4/5: Configuring PostgreSQL database..."

# Start PostgreSQL if not running
pg_isready -q || pg_ctlcluster "$(pg_lsclusters -h | awk '{print $1}' | head -1)" main start

# Create user and databases (idempotent)
su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='msf'\" | grep -q 1 || psql -c \"CREATE USER msf WITH PASSWORD 'msf' CREATEDB;\""
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='msf'\" | grep -q 1 || psql -c \"CREATE DATABASE msf OWNER msf;\""
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='msf_test'\" | grep -q 1 || psql -c \"CREATE DATABASE msf_test OWNER msf;\""

# Write database.yml if it doesn't exist
if [ ! -f "$MSF_ROOT/config/database.yml" ]; then
  cat > "$MSF_ROOT/config/database.yml" <<'DBCONF'
development: &pgsql
  adapter: postgresql
  database: msf
  username: msf
  password: msf
  host: localhost
  port: 5432
  pool: 200
  timeout: 5

production: &production
  <<: *pgsql

test:
  <<: *pgsql
  database: msf_test
  username: msf
  password: msf
DBCONF
  echo "[+] config/database.yml created."
else
  echo "[+] config/database.yml already exists, skipping."
fi

# Copy to ~/.msf4 for msfconsole auto-detection
mkdir -p ~/.msf4
cp "$MSF_ROOT/config/database.yml" ~/.msf4/database.yml

# Run migrations
cd "$MSF_ROOT"
bundle exec rake db:migrate
echo "[+] Database migrations complete."

# -------------------------------------------------------
# 5. Verification
# -------------------------------------------------------
echo ""
echo "[*] Step 5/5: Verifying installation..."
echo ""

RUBY_VER=$(ruby --version)
echo "[+] Ruby:       $RUBY_VER"

BUNDLE_VER=$(bundle --version)
echo "[+] Bundler:    $BUNDLE_VER"

NMAP_VER=$(nmap --version | head -1)
echo "[+] Nmap:       $NMAP_VER"

PG_VER=$(psql --version)
echo "[+] PostgreSQL: $PG_VER"

echo ""
MSF_VER=$(bundle exec ruby "$MSF_ROOT/msfconsole" -q -x "version; exit" 2>/dev/null)
echo "[+] $MSF_VER"

DB_STATUS=$(bundle exec ruby "$MSF_ROOT/msfconsole" -q -x "db_status; exit" 2>/dev/null)
echo "[+] DB Status: $DB_STATUS"

echo ""
echo "[+] ==========================================="
echo "[+] Metasploit Framework installation complete!"
echo "[+] ==========================================="
echo ""
echo "Usage:"
echo "  cd $MSF_ROOT"
echo "  bundle exec ruby msfconsole       # Interactive console"
echo "  bundle exec ruby msfvenom -h      # Payload generator"
echo ""
