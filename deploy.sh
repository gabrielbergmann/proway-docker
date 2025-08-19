#!/usr/bin/env bash
set -euo pipefail

# ==== CONFIGURABLES ====
REPO_URL="${REPO_URL:-https://github.com/gabrielbergmann/proway-docker.git}"
APP_BASE_DIR="${APP_BASE_DIR:-/opt/pizzaria}"
REPO_DIR="${REPO_DIR:-$APP_BASE_DIR/proway-docker}"
# Porta externa onde a plataforma deve responder (redirecionada para 80 do container, a menos que o compose defina outra)
PIZZA_PORT="${PIZZA_PORT:-8080}"
# Se quiser forçar rebuild sempre, exporte ALWAYS_REBUILD=true
ALWAYS_REBUILD="${ALWAYS_REBUILD:-false}"
# Caminho do log do script
LOG_FILE="${LOG_FILE:-/var/log/pizzaria_deploy.log}"
# Nome do serviço para flock (evita corridas quando cron roda de 5/5)
LOCK_FILE="/var/lock/pizzaria_deploy.lock"

# ==== LOGGING ====
mkdir -p "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1

timestamp() { date '+%Y-%m-%d %H:%M:%S%z'; }
log() { echo "[$(timestamp)] $*"; }

# ==== REQUIRE ROOT ====
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

# ==== LOCK ====
flock -n 9 "$LOCK_FILE" || { log "Another deploy is running. Exiting."; exit 0; }
exec 9>"$LOCK_FILE"

# ==== DETECT DISTRO & INSTALL DOCKER ====
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi

  if [ -f /etc/debian_version ]; then
    log "Installing Docker on Debian/Ubuntu..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
      $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git
    systemctl enable --now docker
  elif [ -f /etc/redhat-release ]; then
    log "Installing Docker on RHEL/CentOS/Rocky/Alma..."
    yum install -y yum-utils git
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  else
    log "Unsupported distro. Please install Docker manually and re-run."
    exit 1
  fi
}

# ==== CLONE OR UPDATE REPO ====
sync_repo() {
  mkdir -p "$APP_BASE_DIR"
  if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning repository into $REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
  else
    log "Updating repository in $REPO_DIR"
    git -C "$REPO_DIR" fetch --prune
    git -C "$REPO_DIR" reset --hard origin/$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
    git -C "$REPO_DIR" pull --ff-only || true
  fi
}

# ==== SETUP GIT HOOKS TO FLAG REBUILD ====
setup_hooks() {
  local hookdir="$REPO_DIR/.git/hooks"
  mkdir -p "$hookdir"
  cat > "$hookdir/post-merge" <<'EOF'
#!/usr/bin/env bash
# Mark that a deploy is needed after merges (e.g., remote pulls)
touch "$(git rev-parse --show-toplevel)/.deploy_needed"
EOF
  cat > "$hookdir/post-checkout" <<'EOF'
#!/usr/bin/env bash
# Mark that a deploy is needed when branch/commit changes
touch "$(git rev-parse --show-toplevel)/.deploy_needed"
EOF
  chmod +x "$hookdir/post-merge" "$hookdir/post-checkout"
}

# ==== FIND COMPOSE FILE OR FALL BACK ====
detect_compose() {
  # priority: repo root, then pizzaria-app
  if [ -f "$REPO_DIR/docker-compose.yml" ]; then
    echo "$REPO_DIR/docker-compose.yml"
  elif [ -f "$REPO_DIR/docker-compose.yaml" ]; then
    echo "$REPO_DIR/docker-compose.yaml"
  elif [ -f "$REPO_DIR/pizzaria-app/docker-compose.yml" ]; then
    echo "$REPO_DIR/pizzaria-app/docker-compose.yml"
  elif [ -f "$REPO_DIR/pizzaria-app/docker-compose.yaml" ]; then
    echo "$REPO_DIR/pizzaria-app/docker-compose.yaml"
  else
    echo ""
  fi
}

# ==== REBUILD DECISION ====
should_rebuild() {
  # ALWAYS_REBUILD overrides
  if [[ "$ALWAYS_REBUILD" == "true" ]]; then
    return 0
  fi

  # If the flag file exists (set by hooks), rebuild
  if [ -f "$REPO_DIR/.deploy_needed" ]; then
    return 0
  fi

  # Otherwise, check if there are changes since the last deployed commit
  local last_file="$REPO_DIR/.last_deployed_commit"
  local current_commit
  current_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"

  if [ ! -f "$last_file" ]; then
    # first run
    return 0
  fi

  local last_commit
  last_commit="$(cat "$last_file")"

  # Check diff for files that typically require rebuild (Dockerfile, compose, app src)
  if git -C "$REPO_DIR" diff --name-only "$last_commit" "$current_commit" \
       | grep -E '(^Dockerfile|docker-compose\.ya?ml|^pizzaria-app/|^src/|package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock)'; then
    return 0
  fi

  return 1
}

# ==== EXPORT PORT FOR COMPOSE ====
export_port_env() {
  export PIZZA_PORT
  # Common pattern: compose references ${PIZZA_PORT:-8080}
}

# ==== RUN COMPOSE ====
run_compose() {
  local compose_file="$1"
  if [ -n "$compose_file" ]; then
    log "Using compose file: $compose_file"
    docker compose -f "$compose_file" pull || true
    docker compose -f "$compose_file" up -d --build
  else
    # Fallback: try to build Dockerfile from pizzaria-app/ and publish on PIZZA_PORT:80
    log "No docker-compose found. Using fallback single-container run."
    local ddir="$REPO_DIR/pizzaria-app"
    if [ ! -f "$ddir/Dockerfile" ] && [ -f "$REPO_DIR/Dockerfile" ]; then
      ddir="$REPO_DIR"
    fi
    if [ ! -f "$ddir/Dockerfile" ]; then
      log "No Dockerfile found for fallback. Aborting."
      exit 1
    fi
    local image_name="pizzaria-app:latest"
    docker build --pull -t "$image_name" "$ddir"
    # Ensure a container is running on the expected port
    if docker ps --format '{{.Names}}' | grep -q '^pizzaria-app$'; then
      docker rm -f pizzaria-app || true
    fi
    docker run -d --restart unless-stopped --name pizzaria-app -p "${PIZZA_PORT}:80" "$image_name"
  fi
}

# ==== SAVE DEPLOYED COMMIT & CLEAR FLAGS ====
mark_deployed() {
  local current_commit
  current_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
  echo "$current_commit" > "$REPO_DIR/.last_deployed_commit"
  rm -f "$REPO_DIR/.deploy_needed" || true
}

# ==== CRON INSTALL SELF ====
install_cron() {
  local cron_line="*/5 * * * * root /usr/local/bin/pizzaria_deploy.sh >> /var/log/pizzaria_deploy.log 2>&1"
  if ! crontab -l -u root 2>/dev/null | grep -Fq "/usr/local/bin/pizzaria_deploy.sh"; then
    log "Installing cron entry to run every 5 minutes."
    # Preserve existing root crontab
    { crontab -l -u root 2>/dev/null; echo "$cron_line"; } | crontab -u root -
  else
    log "Cron entry already present."
  fi
}

# ==== MAIN FLOW ====
log "==== Pizzaria deploy started ===="
install_docker
sync_repo
setup_hooks
export_port_env
compose_file="$(detect_compose)"

if should_rebuild; then
  log "Rebuild required."
  run_compose "$compose_file"
  mark_deployed
else
  log "No rebuild needed; ensuring services are up."
  if [ -n "$compose_file" ]; then
    docker compose -f "$compose_file" ps >/dev/null 2>&1 || docker compose -f "$compose_file" up -d
  else
    # Fallback check
    docker ps --format '{{.Names}}' | grep -q '^pizzaria-app$' || run_compose ""
  fi
fi

install_cron
log "==== Pizzaria deploy finished ===="
