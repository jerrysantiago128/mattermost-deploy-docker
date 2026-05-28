#!/usr/bin/env bash
# deploy.sh — Deploy Mattermost with Docker Compose
# Supports: Native Linux, WSL2, Docker Desktop on Windows (Ubuntu)
#
# Usage:
#   ./deploy.sh              # first-time setup + start
#   ./deploy.sh up           # start services
#   ./deploy.sh down         # stop services
#   ./deploy.sh restart      # restart services
#   ./deploy.sh status       # show container status
#   ./deploy.sh logs         # tail logs
#   ./deploy.sh test         # run health check
#
# Options:
#   --host <IP|hostname>     Override the host used in SITEURL (auto-detected by default)
#   --port <port>            Override the app port (default: 8065)
#   --edition <team|enterprise>  Mattermost edition (default: enterprise)
#   --version <tag>          Mattermost image tag (default: 11.7.0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
COMMAND="${1:-up}"
HOST_OVERRIDE=""
APP_PORT="8065"
MM_EDITION="enterprise"
MM_VERSION="11.7.0"

# Parse flags (can appear after the command or as the only args)
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)     HOST_OVERRIDE="$2"; shift 2 ;;
    --port)     APP_PORT="$2";      shift 2 ;;
    --edition)  MM_EDITION="$2";    shift 2 ;;
    --version)  MM_VERSION="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Colors
# --------------------------------------------------------------------------- #
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
die()     { error "$*"; exit 1; }

# --------------------------------------------------------------------------- #
# Environment detection
# --------------------------------------------------------------------------- #
detect_env() {
  if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    echo "wsl2"
  elif [[ -f /proc/sys/kernel/osrelease ]] && grep -qiE "microsoft|wsl" /proc/sys/kernel/osrelease 2>/dev/null; then
    echo "wsl2"
  else
    echo "linux"
  fi
}

# Returns the best host IP for the SITEURL
detect_host_ip() {
  local env
  env="$(detect_env)"

  if [[ "$env" == "wsl2" ]]; then
    # WSL2: Docker Desktop forwards ports to localhost on the Windows host
    echo "localhost"
  else
    # Native Linux: pick the primary non-loopback IPv4
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}')"
    if [[ -z "$ip" ]]; then
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "${ip:-localhost}"
  fi
}

# --------------------------------------------------------------------------- #
# Prerequisite checks
# --------------------------------------------------------------------------- #
check_prerequisites() {
  info "Checking prerequisites..."

  command -v docker &>/dev/null   || die "Docker is not installed. Install Docker Desktop or Docker Engine first."
  docker info &>/dev/null         || die "Docker daemon is not running. Start Docker Desktop or 'sudo systemctl start docker'."

  # Support both 'docker compose' (v2 plugin) and legacy 'docker-compose'
  if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  else
    die "Docker Compose not found. Install Docker Desktop or 'sudo apt install docker-compose-plugin'."
  fi

  success "Docker $(docker --version | awk '{print $3}' | tr -d ',') / Compose ready"
}

# --------------------------------------------------------------------------- #
# .env setup
# --------------------------------------------------------------------------- #
setup_env() {
  if [[ -f .env ]]; then
    info ".env already exists, skipping creation."
    return
  fi

  [[ -f env.example ]] || die "env.example not found. Are you in the right directory?"

  local host_ip
  host_ip="${HOST_OVERRIDE:-$(detect_host_ip)}"
  local env_detected
  env_detected="$(detect_env)"

  info "Detected environment: ${BOLD}${env_detected}${RESET}"
  info "Using host for SITEURL: ${BOLD}${host_ip}${RESET}"

  cp env.example .env

  # Patch the values we know need to change for a fresh deployment
  sed -i "s|^MM_SERVICESETTINGS_SITEURL=.*|MM_SERVICESETTINGS_SITEURL=http://${host_ip}:${APP_PORT}|" .env
  sed -i "s|^APP_PORT=.*|APP_PORT=${APP_PORT}|" .env
  sed -i "s|^MATTERMOST_IMAGE=.*|MATTERMOST_IMAGE=mattermost-${MM_EDITION}-edition|" .env
  sed -i "s|^MATTERMOST_IMAGE_TAG=.*|MATTERMOST_IMAGE_TAG=${MM_VERSION}|" .env

  success ".env created (SITEURL=http://${host_ip}:${APP_PORT})"
  warn "Review .env and change POSTGRES_PASSWORD before production use."
}

# --------------------------------------------------------------------------- #
# Volume directories + permissions
# --------------------------------------------------------------------------- #
setup_volumes() {
  info "Creating volume directories..."

  mkdir -p \
    volumes/app/mattermost/config \
    volumes/app/mattermost/data \
    volumes/app/mattermost/logs \
    volumes/app/mattermost/plugins \
    volumes/app/mattermost/client/plugins \
    volumes/app/mattermost/bleve-indexes \
    volumes/db/var/lib/postgresql/data

  # Mattermost container runs as UID/GID 2000 — fix ownership on Linux.
  # On Docker Desktop (Windows/Mac) this is handled transparently.
  if [[ "$(detect_env)" == "linux" ]]; then
    if sudo chown -R 2000:2000 volumes/app/mattermost 2>/dev/null; then
      success "Set ownership of mattermost volumes to UID/GID 2000"
    else
      warn "Could not chown volumes/app/mattermost — you may see permission errors."
      warn "Run: sudo chown -R 2000:2000 ${SCRIPT_DIR}/volumes/app/mattermost"
    fi
  fi
}

# --------------------------------------------------------------------------- #
# Health check
# --------------------------------------------------------------------------- #
wait_for_healthy() {
  local url="http://localhost:${APP_PORT}/api/v4/system/ping"
  local max_attempts=40
  local attempt=0

  info "Waiting for Mattermost to be ready..."
  while (( attempt < max_attempts )); do
    if curl -sf "$url" &>/dev/null; then
      success "Mattermost is up and healthy!"
      return 0
    fi
    (( attempt++ ))
    printf "."
    sleep 3
  done
  echo ""
  error "Mattermost did not become healthy after $((max_attempts * 3))s."
  error "Check logs with: ./deploy.sh logs"
  return 1
}

run_test() {
  info "Running health check..."
  local port="${APP_PORT}"
  # Read APP_PORT from .env if not overridden on CLI
  if [[ -z "$HOST_OVERRIDE" && -f .env ]]; then
    local env_port
    env_port="$(grep -E '^APP_PORT=' .env | cut -d= -f2)"
    [[ -n "$env_port" ]] && port="$env_port"
  fi

  local url="http://localhost:${port}/api/v4/system/ping"
  local response
  response="$(curl -sf "$url")" || die "Health check failed — is Mattermost running? Try: ./deploy.sh up"

  local status
  status="$(echo "$response" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?")"

  if [[ "$status" == "OK" ]]; then
    success "API ping → status: OK"
    echo -e "  Active search backend : $(echo "$response" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ActiveSearchBackend","?"))' 2>/dev/null)"
  else
    warn "API responded but status is: ${status}"
    echo "$response"
  fi

  # Show container health
  echo ""
  $COMPOSE_CMD ps
}

# --------------------------------------------------------------------------- #
# Main command dispatch
# --------------------------------------------------------------------------- #
check_prerequisites

case "$COMMAND" in

  up)
    setup_env
    setup_volumes
    info "Pulling images and starting services..."
    $COMPOSE_CMD pull --quiet
    $COMPOSE_CMD up -d
    wait_for_healthy
    local_url="http://localhost:${APP_PORT}"
    echo ""
    echo -e "${BOLD}Mattermost is running!${RESET}"
    echo -e "  Local URL  : ${CYAN}${local_url}${RESET}"
    if [[ -f .env ]]; then
      site_url="$(grep -E '^MM_SERVICESETTINGS_SITEURL=' .env | cut -d= -f2)"
      [[ -n "$site_url" && "$site_url" != "$local_url" ]] && \
        echo -e "  Site URL   : ${CYAN}${site_url}${RESET}"
    fi
    ;;

  down)
    info "Stopping services..."
    $COMPOSE_CMD down
    success "Services stopped."
    ;;

  restart)
    info "Restarting services..."
    $COMPOSE_CMD restart
    wait_for_healthy
    ;;

  status)
    $COMPOSE_CMD ps
    ;;

  logs)
    $COMPOSE_CMD logs -f --tail=50
    ;;

  test)
    run_test
    ;;

  -h|--help|help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;

  *)
    die "Unknown command: ${COMMAND}. Run './deploy.sh --help' for usage."
    ;;
esac
