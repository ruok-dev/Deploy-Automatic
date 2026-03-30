#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Script de deploy automatizado para EC2
# Executado remotamente via GitHub Actions (SSH)
# =============================================================================
set -euo pipefail

# ─── Cores para output ───────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ─── Configurações ────────────────────────────────────────────────────────────
readonly APP_DIR="/opt/app"
readonly BACKUP_DIR="/opt/app/backups"
readonly LOG_FILE="/var/log/app/deploy.log"
readonly MAX_BACKUPS=5
readonly HEALTH_CHECK_RETRIES=10
readonly HEALTH_CHECK_INTERVAL=5

# Variáveis injetadas pelo GitHub Actions
: "${REGISTRY:?REGISTRY não definido}"
: "${IMAGE:?IMAGE não definido}"
: "${IMAGE_TAG:?IMAGE_TAG não definido}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN não definido}"
: "${GITHUB_ACTOR:?GITHUB_ACTOR não definido}"
: "${APP_ENV:?APP_ENV não definido}"

# ─── Utilitários ─────────────────────────────────────────────────────────────
log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  case "$level" in
    INFO)  echo -e "${BLUE}[INFO]${NC}  ${timestamp} — ${message}" | tee -a "$LOG_FILE" ;;
    OK)    echo -e "${GREEN}[OK]${NC}    ${timestamp} — ${message}" | tee -a "$LOG_FILE" ;;
    WARN)  echo -e "${YELLOW}[WARN]${NC}  ${timestamp} — ${message}" | tee -a "$LOG_FILE" ;;
    ERROR) echo -e "${RED}[ERROR]${NC} ${timestamp} — ${message}" | tee -a "$LOG_FILE" ;;
  esac
}

die() {
  log ERROR "$*"
  exit 1
}

# ─── Pré-requisitos ──────────────────────────────────────────────────────────
check_prerequisites() {
  log INFO "Verificando pré-requisitos..."

  local deps=("docker" "docker compose" "curl" "jq")
  for dep in "${deps[@]}"; do
    if ! command -v ${dep%% *} &>/dev/null; then
      die "Dependência ausente: $dep"
    fi
  done

  mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
  log OK "Pré-requisitos OK"
}

# ─── Login no registry ───────────────────────────────────────────────────────
registry_login() {
  log INFO "Autenticando no registry ${REGISTRY}..."
  echo "$GITHUB_TOKEN" | docker login "$REGISTRY" \
    --username "$GITHUB_ACTOR" \
    --password-stdin \
    || die "Falha na autenticação no registry"
  log OK "Registry autenticado"
}

# ─── Pull da imagem ──────────────────────────────────────────────────────────
pull_image() {
  local image_ref
  # Pega apenas a primeira tag (a mais específica: sha-)
  image_ref=$(echo "$IMAGE_TAG" | tr ',' '\n' | grep "sha-" | head -1)
  image_ref="${image_ref:-${IMAGE}:latest}"

  log INFO "Baixando imagem: ${image_ref}"
  docker pull "$image_ref" || die "Falha ao fazer pull da imagem"

  # Exporta para uso no compose
  export DEPLOY_IMAGE="$image_ref"
  log OK "Imagem baixada: ${image_ref}"
}

# ─── Backup do container atual ───────────────────────────────────────────────
backup_current() {
  local container_name="app"
  local backup_file="${BACKUP_DIR}/app_backup_$(date +%Y%m%d_%H%M%S).tar"

  if docker inspect "$container_name" &>/dev/null; then
    log INFO "Fazendo backup do container atual..."
    docker export "$container_name" > "$backup_file" 2>/dev/null || true
    log OK "Backup salvo em: ${backup_file}"

    # Mantém apenas os N backups mais recentes
    ls -t "${BACKUP_DIR}"/app_backup_*.tar 2>/dev/null \
      | tail -n +$((MAX_BACKUPS + 1)) \
      | xargs -r rm -f
  else
    log WARN "Nenhum container em execução — backup ignorado"
  fi
}

# ─── Deploy com zero-downtime ─────────────────────────────────────────────────
deploy() {
  log INFO "Iniciando deploy no ambiente: ${APP_ENV}"

  cd "$APP_DIR"

  # Injeta variáveis de ambiente para o compose
  export APP_ENV
  export DEPLOY_IMAGE

  # Sobe novo container
  docker compose -f "docker-compose.${APP_ENV}.yml" pull
  docker compose -f "docker-compose.${APP_ENV}.yml" up -d \
    --remove-orphans \
    --force-recreate \
    --no-build

  log OK "Containers recriados"
}

# ─── Health check ────────────────────────────────────────────────────────────
health_check() {
  local health_url="${HEALTH_CHECK_URL:-http://localhost:${APP_PORT:-3000}/health}"
  log INFO "Verificando saúde da aplicação em: ${health_url}"

  local attempt=1
  while [[ $attempt -le $HEALTH_CHECK_RETRIES ]]; do
    log INFO "Tentativa ${attempt}/${HEALTH_CHECK_RETRIES}..."

    local http_code
    http_code=$(curl --silent --output /dev/null --write-out "%{http_code}" \
      --max-time 5 "$health_url" || echo "000")

    if [[ "$http_code" == "200" ]]; then
      log OK "Health check passou (HTTP ${http_code})"
      return 0
    fi

    log WARN "Health check falhou (HTTP ${http_code}). Aguardando ${HEALTH_CHECK_INTERVAL}s..."
    sleep "$HEALTH_CHECK_INTERVAL"
    ((attempt++))
  done

  die "Health check falhou após ${HEALTH_CHECK_RETRIES} tentativas. Iniciando rollback..."
}

# ─── Rollback ────────────────────────────────────────────────────────────────
rollback() {
  log WARN "Iniciando rollback..."

  cd "$APP_DIR"

  # Tenta subir a versão anterior via imagem anterior no registry
  if docker inspect app_previous &>/dev/null; then
    docker tag app_previous "${IMAGE}:rollback"
    export DEPLOY_IMAGE="${IMAGE}:rollback"
    docker compose -f "docker-compose.${APP_ENV}.yml" up -d \
      --force-recreate \
      --no-build \
      || die "Rollback também falhou. Intervenção manual necessária."
    log OK "Rollback concluído"
  else
    die "Nenhuma versão anterior disponível para rollback"
  fi
}

# ─── Limpeza de recursos Docker ──────────────────────────────────────────────
cleanup() {
  log INFO "Limpando recursos Docker não utilizados..."
  docker image prune -f --filter "until=24h" || true
  docker container prune -f || true
  log OK "Limpeza concluída"
}

# ─── Resumo do deploy ─────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║        ✅  DEPLOY CONCLUÍDO            ║${NC}"
  echo -e "${GREEN}╠════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║${NC} Ambiente : ${APP_ENV}"
  echo -e "${GREEN}║${NC} Imagem   : ${DEPLOY_IMAGE}"
  echo -e "${GREEN}║${NC} Data/hora: $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
  echo ""
}

# ─── Trap para rollback automático em caso de falha ──────────────────────────
trap 'log ERROR "Deploy falhou! Executando rollback automático..."; rollback' ERR

# ─── Execução principal ───────────────────────────────────────────────────────
main() {
  log INFO "═══════════════════════════════════════════"
  log INFO "  Iniciando pipeline de deploy"
  log INFO "═══════════════════════════════════════════"

  check_prerequisites
  registry_login
  pull_image
  backup_current
  deploy
  health_check
  cleanup
  print_summary
}

main "$@"
