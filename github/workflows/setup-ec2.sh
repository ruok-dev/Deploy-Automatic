#!/usr/bin/env bash
# =============================================================================
# setup-ec2.sh — Provisionamento inicial da instância EC2
# Execute UMA VEZ como root após criar a instância
# =============================================================================
set -euo pipefail

readonly APP_USER="deploy"
readonly APP_DIR="/opt/app"
readonly LOG_DIR="/var/log/app"

echo "🚀 Iniciando provisionamento da EC2..."

# ─── Atualiza sistema ─────────────────────────────────────────────────────────
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  curl wget git jq unzip \
  ca-certificates gnupg lsb-release \
  ufw fail2ban

# ─── Instala Docker ───────────────────────────────────────────────────────────
echo "📦 Instalando Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# ─── Cria usuário de deploy ───────────────────────────────────────────────────
echo "👤 Criando usuário ${APP_USER}..."
if ! id "$APP_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$APP_USER"
fi
usermod -aG docker "$APP_USER"

# ─── Cria estrutura de diretórios ─────────────────────────────────────────────
echo "📁 Criando estrutura de diretórios..."
mkdir -p \
  "${APP_DIR}/scripts" \
  "${APP_DIR}/backups" \
  "${APP_DIR}/nginx/certs" \
  "$LOG_DIR"

chown -R "${APP_USER}:${APP_USER}" "$APP_DIR" "$LOG_DIR"

# ─── Configura logrotate ──────────────────────────────────────────────────────
cat > /etc/logrotate.d/app << 'EOF'
/var/log/app/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0644 deploy deploy
}
EOF

# ─── Configura firewall (UFW) ─────────────────────────────────────────────────
echo "🔒 Configurando firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw --force enable

# ─── Configura fail2ban ───────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ─── Desabilita login root via SSH ───────────────────────────────────────────
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload sshd

echo ""
echo "✅ Provisionamento concluído!"
echo "   Usuário de deploy : ${APP_USER}"
echo "   Diretório da app  : ${APP_DIR}"
echo "   Logs              : ${LOG_DIR}"
echo ""
echo "⚠️  Próximos passos:"
echo "   1. Adicione a chave SSH pública do GitHub Actions em ~${APP_USER}/.ssh/authorized_keys"
echo "   2. Copie docker-compose.*.yml e scripts/ para ${APP_DIR}"
echo "   3. Configure o arquivo .env de produção em ${APP_DIR}/.env"
