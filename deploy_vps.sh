#!/usr/bin/env bash
# ============================================================
# MyOffrimo Engine — One-shot VPS deployment
# Target: Hetzner CX33 (Ubuntu 24.04), 4 vCPU, 8GB RAM
# ============================================================
set -euo pipefail

echo "══════════════════════════════════════════════════════════"
echo "  MyOffrimo Engine — VPS Deployment"
echo "  $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "══════════════════════════════════════════════════════════"

# ── 1. System packages ──────────────────────────────────────
echo "[1/7] System update + Docker install..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release git unzip htop \
  fail2ban ufw

# Docker
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
fi

# Docker Compose plugin
if ! docker compose version &>/dev/null; then
  apt-get install -y -qq docker-compose-plugin
fi

echo "  Docker $(docker --version)"
echo "  Compose $(docker compose version)"

# ── 2. Firewall ─────────────────────────────────────────────
echo "[2/7] Firewall setup..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 8091/tcp
ufw allow 8080/tcp
ufw allow 9090/tcp
ufw allow 3001/tcp
ufw --force enable
echo "  UFW active"

# ── 3. Create app user + dirs ───────────────────────────────
echo "[3/7] App user setup..."
if ! id myoffrimo &>/dev/null; then
  useradd -m -s /bin/bash myoffrimo
  usermod -aG docker myoffrimo
fi

APP_DIR=/opt/myoffrimo
mkdir -p $APP_DIR /opt/myoffrimo/data/postgres /opt/myoffrimo/data/minio /opt/myoffrimo/backups

# ── 4. Clone private repo ──────────────────────────────────
echo "[4/7] Clone repo..."
echo ""
echo "  The repo is private. You need a GitHub Personal Access Token."
echo "  If you don't have one, go to:"
echo "    https://github.com/settings/tokens/new"
echo "  Check 'repo' scope, generate, and paste it here."
echo ""
read -sp "  GitHub Personal Access Token (paste, nothing shows): " GH_TOKEN
echo ""

if [ -z "$GH_TOKEN" ]; then
  echo "  ERROR: No token provided. Skipping clone."
  echo "  You can clone manually later:"
  echo "    git clone https://YOUR_TOKEN@github.com/phippsou-dev/myhome-connect-suite.git /opt/myoffrimo/repo"
else
  if [ -d "$APP_DIR/repo" ]; then
    cd $APP_DIR/repo && git pull origin main
  else
    git clone "https://${GH_TOKEN}@github.com/phippsou-dev/myhome-connect-suite.git" $APP_DIR/repo
  fi
  echo "  Repo cloned OK"
fi

ENGINE_DIR=$APP_DIR/repo/services/myoffrimo-ingestion
cd $ENGINE_DIR 2>/dev/null || { echo "ERROR: Engine dir not found"; exit 1; }

# ── 5. Environment file ────────────────────────────────────
echo "[5/7] Environment setup..."
ENV_FILE=$ENGINE_DIR/.env.prod

if [ ! -f "$ENV_FILE" ]; then
  ADMIN_KEY=$(openssl rand -hex 16)
  MINIO_SECRET=$(openssl rand -hex 8)

  cat > $ENV_FILE << ENVEOF
MYOFFRIMO_ENV=prod
MYOFFRIMO_HOST=0.0.0.0
MYOFFRIMO_PORT=8091
MYOFFRIMO_EXPOSE_DOCS=false
MYOFFRIMO_LOG_LEVEL=INFO
MYOFFRIMO_DATABASE_URL=postgresql+psycopg://myoffrimo:myoffrimo_prod_2026@postgres:5432/myoffrimo_ingestion
MYOFFRIMO_REDIS_URL=redis://redis:6379/0
MYOFFRIMO_ADMIN_API_KEY=${ADMIN_KEY}
MYOFFRIMO_TRUSTED_HOSTS_CSV=localhost,127.0.0.1,proxy
MYOFFRIMO_CORS_ALLOW_ORIGINS_CSV=https://myhome-connect-suite.lovable.app,http://localhost:3000
MYOFFRIMO_RATE_LIMIT_REQUESTS=80
MYOFFRIMO_RATE_LIMIT_WINDOW_SECONDS=60
MYOFFRIMO_S3_ENDPOINT=http://minio:9000
MYOFFRIMO_S3_BUCKET=myoffrimo-bronze-prod
MYOFFRIMO_S3_ACCESS_KEY=minio
MYOFFRIMO_S3_SECRET_KEY=${MINIO_SECRET}
MYOFFRIMO_ENABLE_PLAYWRIGHT=true
MYOFFRIMO_AI_ENABLED=false
MYOFFRIMO_AI_PROVIDER=noop
MYOFFRIMO_EMBEDDINGS_ENABLED=false
MYOFFRIMO_SUPABASE_URL=https://ykpkkkivoydungkjbxzf.supabase.co
MYOFFRIMO_SUPABASE_KEY=PASTE_YOUR_SUPABASE_SERVICE_ROLE_KEY_HERE
MYOFFRIMO_SUPABASE_ENABLED=true
MYOFFRIMO_PUBLICATION_ENDPOINT=disabled
MYOFFRIMO_PUBLICATION_MODE=supabase_direct
MYOFFRIMO_ALERT_ENABLED=false
BACKUP_RETENTION_DAYS=30
ENVEOF
  echo "  .env.prod created (admin_key auto-generated)"
  echo "  ⚠️  You still need to add MYOFFRIMO_SUPABASE_KEY"
fi

# ── 6. Docker compose override ─────────────────────────────
echo "[6/7] Docker compose prod override..."
cat > $ENGINE_DIR/docker-compose.prod-vps.yml << 'YMLEOF'
version: "3.9"
services:
  postgres:
    environment:
      POSTGRES_PASSWORD: myoffrimo_prod_2026
    volumes:
      - /opt/myoffrimo/data/postgres:/var/lib/postgresql/data
    restart: always
  redis:
    restart: always
  api:
    env_file:
      - .env.prod
    restart: always
  worker:
    env_file:
      - .env.prod
    restart: always
  scheduler:
    env_file:
      - .env.prod
    restart: always
  migrate:
    env_file:
      - .env.prod
  minio:
    volumes:
      - /opt/myoffrimo/data/minio:/data
    restart: always
  backup:
    env_file:
      - .env.prod
    volumes:
      - /opt/myoffrimo/backups:/backups
    restart: always
YMLEOF

# ── 7. Systemd service ─────────────────────────────────────
echo "[7/7] Systemd service..."
cat > /etc/systemd/system/myoffrimo.service << SVCEOF
[Unit]
Description=MyOffrimo Ingestion Engine
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ENGINE_DIR
ExecStart=/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod-vps.yml up -d --build
ExecStop=/usr/bin/docker compose -f docker-compose.yml -f docker-compose.prod-vps.yml down
User=root
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable myoffrimo.service
chown -R myoffrimo:myoffrimo /opt/myoffrimo

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  ✅ INSTALLATION COMPLETE"
echo "══════════════════════════════════════════════════════════"
echo ""
echo "  NEXT STEPS:"
echo ""
echo "  1. Add your Supabase service_role key:"
echo "     nano $ENV_FILE"
echo "     → Change MYOFFRIMO_SUPABASE_KEY=..."
echo ""
echo "  2. Start the engine:"
echo "     cd $ENGINE_DIR"
echo "     docker compose -f docker-compose.yml -f docker-compose.prod-vps.yml up -d --build"
echo ""
echo "  3. First crawl:"
echo "     docker compose exec api python -m app.production.scheduler refresh"
echo ""
echo "══════════════════════════════════════════════════════════"
