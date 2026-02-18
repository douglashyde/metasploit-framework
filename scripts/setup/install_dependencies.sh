#!/bin/bash
# Metasploit Framework - Full Dependency Installation Script
# Supports macOS (Homebrew) and Ubuntu/Debian (apt)
# Usage: sudo ./scripts/setup/install_dependencies.sh

set -e

echo "[*] Metasploit Framework Dependency Installer"
echo "[*] ==========================================="

MSF_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "[*] Metasploit root: $MSF_ROOT"

OS="$(uname -s)"
echo "[*] Detected OS: $OS"

# -------------------------------------------------------
# 1. System packages
# -------------------------------------------------------
echo ""
echo "[*] Step 1/5: Installing system packages..."

if [ "$OS" = "Darwin" ]; then
  # macOS - use Homebrew (do NOT run brew as root)
  if [ "$EUID" -eq 0 ]; then
    echo "[-] On macOS, do NOT run this script with sudo."
    echo "    Run it directly: bash scripts/setup/install_dependencies.sh"
    exit 1
  fi

  if ! command -v brew &> /dev/null; then
    echo "[-] Homebrew not found. Install it first:"
    echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi

  brew update
  brew install \
    autoconf \
    bison \
    curl \
    git \
    libpq \
    libpcap \
    libxml2 \
    libxslt \
    libyaml \
    nmap \
    openssl@3 \
    postgresql@16 \
    readline \
    ruby \
    sqlite \
    wget \
    zlib

  # Ensure brew ruby is on PATH
  BREW_PREFIX="$(brew --prefix)"
  export PATH="$BREW_PREFIX/opt/ruby/bin:$BREW_PREFIX/opt/postgresql@16/bin:$PATH"

  # Link libpq headers for pg gem
  brew link --force libpq 2>/dev/null || true

  echo "[+] System packages installed via Homebrew."

elif [ -f /etc/debian_version ]; then
  # Debian/Ubuntu - use apt
  if [ "$EUID" -ne 0 ]; then
    echo "[-] On Linux, this script must be run as root (use sudo)"
    exit 1
  fi

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

  echo "[+] System packages installed via apt."
else
  echo "[-] Unsupported OS. This script supports macOS and Debian/Ubuntu."
  exit 1
fi

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

# nproc is Linux-only; use sysctl on macOS
if [ "$OS" = "Darwin" ]; then
  NUM_JOBS=$(sysctl -n hw.ncpu)
else
  NUM_JOBS=$(nproc)
fi
bundle config set --local jobs "$NUM_JOBS"
bundle install
echo "[+] All gems installed."

# -------------------------------------------------------
# 4. PostgreSQL database setup
# -------------------------------------------------------
echo ""
echo "[*] Step 4/5: Configuring PostgreSQL database..."

if [ "$OS" = "Darwin" ]; then
  # macOS: start PostgreSQL via brew services
  brew services start postgresql@16 2>/dev/null || true
  sleep 2

  # On macOS, the current user can run psql directly
  psql postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='msf'" | grep -q 1 \
    || psql postgres -c "CREATE USER msf WITH PASSWORD 'msf' CREATEDB;"
  psql postgres -tc "SELECT 1 FROM pg_database WHERE datname='msf'" | grep -q 1 \
    || psql postgres -c "CREATE DATABASE msf OWNER msf;"
  psql postgres -tc "SELECT 1 FROM pg_database WHERE datname='msf_test'" | grep -q 1 \
    || psql postgres -c "CREATE DATABASE msf_test OWNER msf;"
else
  # Linux: start PostgreSQL and use postgres user
  pg_isready -q || pg_ctlcluster "$(pg_lsclusters -h | awk '{print $1}' | head -1)" main start

  su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='msf'\" | grep -q 1 || psql -c \"CREATE USER msf WITH PASSWORD 'msf' CREATEDB;\""
  su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='msf'\" | grep -q 1 || psql -c \"CREATE DATABASE msf OWNER msf;\""
  su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='msf_test'\" | grep -q 1 || psql -c \"CREATE DATABASE msf_test OWNER msf;\""
fi

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
echo "  bundle exec ruby tools/dashboard/app.rb  # Web dashboard"
echo ""
