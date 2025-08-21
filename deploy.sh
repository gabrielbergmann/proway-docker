#!/usr/bin/env bash
set -euo pipefail

# =============== CONFIG ===============
REPO_URL="${REPO_URL:-https://github.com/gabrielbergmann/proway-docker.git}"
BASE_DIR="${BASE_DIR:-/opt/pizzaria}"
APP_DIR="${APP_DIR:-$BASE_DIR/proway-docker}"
LOG_FILE="${LOG_FILE:-/var/log/pizzaria_deploy.log}"
CRON_FILE="/etc/cron.d/pizzaria-deploy"
LOCK_FILE="/var/lock/pizzaria_deploy.lock"

# Porta externa exposta pelo compose (use ${PIZZA_PORT:-8080} no docker-compose.yml)
PIZZA_PORT="${PIZZA_PORT:-8080}"

# Force rebuild em toda execução: export ALWAYS_REBUILD=true
ALWAYS_REBUILD="${ALWAYS_REBUILD:-false}"
# =====================================

log() { echo "[deploy] $*"; }
die() { echo "[deploy][ERROR] $*" >&2; exit 1; }
need_root() { [ "$EUID" -eq 0 ] || die "Execute como root (sudo)."; }

install_prereqs() {
  log "Instalando dependências (curl, git, docker.io, docker-compose)..."
  apt update -y
  apt install -y curl git docker.io docker-compose
  systemctl enable --now docker
}

clone_or_update_repo() {
  if [ ! -d "$APP_DIR/.git" ]; then
    log "Clonando repositório em $APP_DIR ..."
    git clone "$REPO_URL" "$APP_DIR" || die "Falha no git clone."
  else
    log "Atualizando repositório ..."
    git -C "$APP_DIR" fetch --all --prune || die "Falha em git fetch."
    local DEFAULT_BRANCH
    DEFAULT_BRANCH="$(git -C "$APP_DIR" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||' || true)"
    [ -z "${DEFAULT_BRANCH:-}" ] && DEFAULT_BRANCH="main"
    git -C "$APP_DIR" checkout -f "$DEFAULT_BRANCH"
    git -C "$APP_DIR" reset --hard "origin/$DEFAULT_BRANCH"
  fi
}

setup_hooks() {
  local hookdir="$APP_DIR/.git/hooks"
  mkdir -p "$hookdir"

  cat > "$hookdir/post-merge" <<'EOF'
#!/usr/bin/env bash
touch "$(git rev-parse --show-toplevel)/.deploy_needed"
EOF

  cat > "$hookdir/post-checkout" <<'EOF'
#!/usr/bin/env bash
touch "$(git rev-parse --show-toplevel)/.deploy_needed"
EOF

  chmod +x "$hookdir/post-merge" "$hookdir/post-checkout"
  log "Git hooks instalados (post-merge, post-checkout)."
}

detect_compose() {
  if   [ -f "$APP_DIR/docker-compose.yml" ]; then echo "$APP_DIR/docker-compose.yml"
  elif [ -f "$APP_DIR/docker-compose.yaml" ]; then echo "$APP_DIR/docker-compose.yaml"
  elif [ -f "$APP_DIR/pizzaria-app/docker-compose.yml" ]; then echo "$APP_DIR/pizzaria-app/docker-compose.yml"
  elif [ -f "$APP_DIR/pizzaria-app/docker-compose.yaml" ]; then echo "$APP_DIR/pizzaria-app/docker-compose.yaml"
  else echo ""
  fi
}

should_rebuild() {
  [ "$ALWAYS_REBUILD" = "true" ] && return 0
  [ -f "$APP_DIR/.deploy_needed" ] && return 0
  return 1
}

mark_deployed() {
  rm -f "$APP_DIR/.deploy_needed" || true
}

run_compose_build_up() {
  export PIZZA_PORT
  local compose_file="$1"

  if [ -n "$compose_file" ]; then
    log "Executando docker-compose com rebuild (arquivo: $compose_file)..."
    docker-compose -f "$compose_file" pull || true
    docker-compose -f "$compose_file" up -d --build
  else
    log "Nenhum docker-compose encontrado. Fallback com Dockerfile..."
    local BUILD_CTX="$APP_DIR"
    [ -f "$APP_DIR/pizzaria-app/Dockerfile" ] && BUILD_CTX="$APP_DIR/pizzaria-app"
    [ -f "$BUILD_CTX/Dockerfile" ] || die "Não há docker-compose nem Dockerfile no repositório."
    docker build --pull -t pizzaria-app:latest "$BUILD_CTX"
    docker rm -f pizzaria-app >/dev/null 2>&1 || true
    docker run -d --restart unless-stopped --name pizzaria-app -p "${PIZZA_PORT}:80" pizzaria-app:latest
  fi
}

ensure_running() {
  export PIZZA_PORT
  local compose_file="$1"

  if [ -n "$compose_file" ]; then
    # Se não há containers do projeto, sobe do zero com build
    if [ -z "$(docker-compose -f "$compose_file" ps -q)" ]; then
      log "Nenhum container do compose encontrado — subindo stack com build..."
      docker-compose -f "$compose_file" pull || true
      docker-compose -f "$compose_file" up -d --build
    else
      log "Containers existentes detectados — garantindo que estão up..."
      docker-compose -f "$compose_file" up -d
    fi
  else
    # Fallback single-container
    if ! docker inspect -f '{{.State.Running}}' pizzaria-app >/dev/null 2>&1; then
      log "Fallback: container 'pizzaria-app' não está rodando — (re)criando..."
      run_compose_build_up ""
    else
      log "Fallback: 'pizzaria-app' já está rodando."
    fi
  fi
}

install_cron() {
  if [ ! -f "$CRON_FILE" ]; then
    log "Instalando cron (*/5 min) em $CRON_FILE ..."
    echo "*/5 * * * * root $APP_DIR/deploy.sh >> $LOG_FILE 2>&1" > "$CRON_FILE"
    chmod +x "$APP_DIR/proway-docker/deploy.sh"
    chmod 644 "$CRON_FILE"
    systemctl restart cron || service cron restart || true
  fi
}

main() {
  need_root
  mkdir -p "$(dirname "$LOG_FILE")" "$BASE_DIR"

  # Evita corrida quando o cron chamar de 5/5
  exec 9>"$LOCK_FILE" || true
  if ! flock -n 9; then log "Outra execução em andamento; saindo."; exit 0; fi

  log "Iniciando deploy..."
  install_prereqs
  clone_or_update_repo
  setup_hooks

  local COMPOSE_FILE
  COMPOSE_FILE="$(detect_compose)"

  if should_rebuild; then
    log "Rebuild necessário (hook/flag detectado)."
    run_compose_build_up "$COMPOSE_FILE"
    mark_deployed
  else
    log "Nenhuma mudança sinalizada; garantindo serviços em execução."
    ensure_running "$COMPOSE_FILE"
  fi

  install_cron
  log "Concluído. Logs: $LOG_FILE"
  log "Lista de serviços executando --------------------------------"
}

main "$@"
