# 🚀 Deploy Automático na AWS com Docker

Pipeline de CI/CD completo para deploy de containers na AWS EC2 usando GitHub Actions.

![CI/CD](https://img.shields.io/badge/CI%2FCD-GitHub_Actions-2088FF?logo=github-actions)
![Docker](https://img.shields.io/badge/Container-Docker-2496ED?logo=docker)
![AWS](https://img.shields.io/badge/Cloud-AWS_EC2-FF9900?logo=amazon-aws)

---

## 📐 Arquitetura

```
GitHub Push (main/staging)
        │
        ▼
┌───────────────────┐
│  Job 1 — Test     │  Lint + Testes + Coverage
└────────┬──────────┘
         │ (sucesso)
         ▼
┌───────────────────┐
│  Job 2 — Build    │  Multi-stage Docker build
│                   │  Push → GitHub Container Registry (ghcr.io)
└────────┬──────────┘
         │ (sucesso)
         ▼
┌───────────────────┐
│  Job 3 — Deploy   │  SSH → EC2 → deploy.sh
│                   │  Health check → Rollback automático
└───────────────────┘
```

---

## 📁 Estrutura do Repositório

```
.
├── .github/
│   └── workflows/
│       └── deploy.yml              # Pipeline CI/CD principal
├── scripts/
│   ├── deploy.sh                   # Script de deploy (roda na EC2)
│   └── setup-ec2.sh               # Provisionamento inicial da EC2
├── nginx/
│   └── nginx.conf                  # Config do reverse proxy
├── docker-compose.production.yml   # Compose de produção
├── docker-compose.staging.yml      # Compose de staging
└── Dockerfile                      # Multi-stage build otimizado
```

---

## ⚙️ Configuração

### 1. Secrets no GitHub

Vá em **Settings → Secrets and variables → Actions** e adicione:

| Secret               | Descrição                                  |
|----------------------|--------------------------------------------|
| `EC2_HOST_PROD`      | IP ou domínio da instância de produção     |
| `EC2_HOST_STAGING`   | IP ou domínio da instância de staging      |
| `EC2_USER`           | Usuário SSH (ex: `deploy`)                 |
| `EC2_SSH_KEY`        | Chave SSH privada (PEM inteiro)            |
| `PROD_APP_URL`       | URL pública de produção                    |
| `STAGING_APP_URL`    | URL pública de staging                     |

### 2. Provisionamento da EC2 (uma vez só)

```bash
# Na sua máquina local
ssh ec2-user@<SEU_IP_EC2>

# Na EC2, como root
sudo bash setup-ec2.sh
```

### 3. Adicionar chave SSH do GitHub Actions

Gere um par de chaves dedicado para o deploy:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
```

- **Chave pública** → adicione em `/home/deploy/.ssh/authorized_keys` na EC2  
- **Chave privada** → adicione como secret `EC2_SSH_KEY` no GitHub

### 4. Copiar arquivos para a EC2

```bash
scp docker-compose.production.yml deploy@<EC2_IP>:/opt/app/
scp scripts/deploy.sh deploy@<EC2_IP>:/opt/app/scripts/
chmod +x /opt/app/scripts/deploy.sh
```

---

## 🔄 Fluxo de Deploy

| Branch    | Ambiente   | Trigger          |
|-----------|------------|------------------|
| `main`    | Production | Push / Merge PR  |
| `staging` | Staging    | Push             |
| PRs       | —          | Apenas testes    |

---

## 🩺 Health Check

A aplicação deve expor um endpoint `/health` retornando `HTTP 200`:

```json
{ "status": "ok", "timestamp": "2025-01-01T00:00:00Z" }
```

O deploy só é considerado bem-sucedido após **10 tentativas** com intervalo de **5s**.  
Em caso de falha, o rollback é executado automaticamente.

---

## 🔁 Rollback Manual

```bash
ssh deploy@<EC2_IP>
cd /opt/app

# Lista backups disponíveis
ls -lh backups/

# Para reverter para imagem anterior
docker compose -f docker-compose.production.yml up -d --force-recreate
```

---

## 🔒 Segurança

- Imagem roda como **usuário não-root**
- Firewall UFW: apenas portas 22, 80, 443
- **fail2ban** ativo contra brute force SSH
- Login root e autenticação por senha **desabilitados**
- Secrets via GitHub Actions (nunca em código)
- Imagens com **multi-stage build** (menor superfície de ataque)

---

## 📊 Monitoramento

```bash
# Logs da aplicação em tempo real
docker compose -f docker-compose.production.yml logs -f app

# Status dos containers
docker compose -f docker-compose.production.yml ps

# Histórico de deploys
cat /var/log/app/deploy.log
```
