#!/usr/bin/env bash
# Background Termix updater with credential collection, crash recovery, and smart restart
# 
# This script:
# - Collects all credentials and permissions upfront (sudo, Termix admin)
# - Runs the actual update in the background to prevent crashing the current instance
# - Detects if the update process crashes and restarts Termix
# - Restarts Termix once updates complete successfully
# - Debian-compatible with proper process tracking
# 
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/alexdatskov-tech/termix-autoupdate/main/update-bg.sh | bash

set -uo pipefail

REPO="alexd-aero/termix-autoupdate"
SCRIPT_URL="https://raw.githubusercontent.com/$REPO/main/update.sh"
BACKGROUND_UPDATER="/usr/local/lib/termix-autoupdate/background-update.sh"
LIB="/usr/local/lib/termix-autoupdate"
LOG_DIR="/var/log/termix-autoupdate"
CREDS_DIR="/etc/termix-autoupdate"
LOCK_FILE="/run/termix-autoupdate.lock"
PID_FILE="/run/termix-autoupdate.pid"

# Color codes for output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; B=$'\e[1m'
else
  G=; Y=; R=; D=; N=; B=
fi

ok()   { echo "  ${G}✓${N} $*"; }
info() { echo "  ${D}·${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
fail() { echo "  ${R}✗${N} $*"; }
head() { echo; echo "  ${B}$*${N}"; }

# ================================================================ Privilege check
if [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null 2>&1 || { fail "please run as root or with sudo"; exit 1; }
  self="$(mktemp)"
  trap 'rm -f "$self"' EXIT
  if [ -f "${BASH_SOURCE[0]:-}" ]; then 
    cp "${BASH_SOURCE[0]}" "$self"
  else 
    curl -fsSL "$SCRIPT_URL" -o "$self" || { fail "download failed"; exit 1; }
  fi
  info "requesting sudo access…"
  sudo INVOKING_USER="$(id -un)" INVOKING_HOME="$HOME" bash "$self"
  exit $?
fi

INVOKING_USER="${INVOKING_USER:-${SUDO_USER:-root}}"
INVOKING_HOME="${INVOKING_HOME:-$(getent passwd "$INVOKING_USER" | cut -d: -f6)}"
BACKUP_DIR="${INVOKING_HOME:-/root}/termix-backups"

# ================================================================ Prevent concurrent runs
acquire_lock() {
  local timeout=30 elapsed=0
  while [ -f "$LOCK_FILE" ]; do
    if [ $elapsed -ge $timeout ]; then
      fail "another update is already running (lock: $LOCK_FILE)"
      return 1
    fi
    info "waiting for previous update to complete ($elapsed/$timeout seconds)…"
    sleep 2
    ((elapsed += 2))
  done
  touch "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

# ================================================================ Debian system detection
is_debian_based() {
  [ -f /etc/os-release ] && grep -qi "debian\|ubuntu" /etc/os-release
}

ensure_dependencies() {
  head "Checking dependencies for Debian systems…"
  
  local missing=()
  for cmd in docker curl tar grep sed; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    info "Installing missing packages: ${missing[*]}"
    if is_debian_based; then
      apt-get update >/dev/null 2>&1 && apt-get install -y "${missing[@]}" >/dev/null 2>&1 && ok "dependencies installed" || {
        fail "could not install dependencies: ${missing[*]}"
        return 1
      }
    fi
  fi
}

# ================================================================ Credential collection
collect_credentials() {
  head "Collecting credentials and permissions…"
  
  # Check if Docker is available
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "Docker is not available or not running"
    return 1
  fi
  
  # Find Termix containers
  local containers
  containers="$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.State}}' | grep -i termix | awk '{print $1}' | head -1)"
  
  if [ -z "$containers" ]; then
    warn "no Termix container found"
    return 1
  fi
  
  ok "found Termix container: $containers"
  echo "$containers" > "$CREDS_DIR/termix-container" 2>/dev/null || {
    mkdir -p "$CREDS_DIR"
    echo "$containers" > "$CREDS_DIR/termix-container"
    chmod 700 "$CREDS_DIR"
  }
  
  # Check for existing API key
  if [ -s "$CREDS_DIR/api-key-$containers" ]; then
    local status
    status="$(docker exec "$containers" node -e "
      fetch('http://127.0.0.1:30001/plugins', { headers: { Authorization: 'Bearer ' + process.env.KEY } })
        .then(r => r.status)
        .catch(() => 0)
    " 2>/dev/null || echo 0)"
    
    if [ "$status" = 200 ]; then
      ok "existing Termix API key is valid"
      return 0
    fi
    warn "existing API key is invalid, need to re-authenticate"
  fi
  
  # Interactive login for API key creation
  info "Termix admin authentication required (one-time setup)"
  info "This creates an API key named 'termix-autoupdate' (password not stored)"
  
  local user pass attempts=0
  while [ $attempts -lt 3 ]; do
    read -r -p "  Termix admin username: " user </dev/tty
    read -r -s -p "  Termix admin password: " pass </dev/tty
    echo
    
    local token
    token="$(docker exec -i -e U="$user" -e P="$pass" "$containers" node -e '
      const base = "http://127.0.0.1:30001";
      const j = { "Content-Type": "application/json" };
      (async () => {
        try {
          let r = await fetch(base + "/users/login", {
            method: "POST",
            headers: j,
            body: JSON.stringify({ username: process.env.U, password: process.env.P })
          });
          let body = await r.json().catch(() => ({}));
          let jwt = ((r.headers.getSetCookie?.() || []).join(";").match(/jwt=([^;]+)/) || [])[1];
          
          if (body.requires_totp) {
            process.stderr.write("  2FA code: ");
            await new Promise(res => process.stdin.once("data", d => res()));
            // 2FA handling would go here if needed
          }
          
          if (!jwt || !body.is_admin) {
            console.log("ERR " + (body.error || "not an admin account"));
            return;
          }
          
          const k = await fetch(base + "/users/api-keys", {
            method: "POST",
            headers: { ...j, Cookie: "jwt=" + jwt },
            body: JSON.stringify({ name: "termix-autoupdate", userId: body.userId })
          });
          const kb = await k.json().catch(() => ({}));
          console.log(kb.token ? "KEY " + kb.token : "ERR " + (kb.error || "could not create API key"));
        } catch(e) {
          console.log("ERR " + e.message);
        }
      })();
    ' < /dev/tty)" 2>/dev/null)
    
    if [[ "$token" == KEY\ * ]]; then
      mkdir -p "$CREDS_DIR"
      (umask 077; echo "${token#KEY }" > "$CREDS_DIR/api-key-$containers")
      chmod 700 "$CREDS_DIR"
      ok "API key created and stored securely"
      return 0
    fi
    
    fail "${token#ERR }"
    ((attempts++))
  done
  
  fail "authentication failed after 3 attempts"
  return 1
}

# ================================================================ Process monitoring
get_termix_pid() {
  local container="$1"
  # Get the PID of the main Termix process inside the container
  docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || echo ""
}

is_termix_running() {
  local container="$1"
  docker ps --format '{{.Names}}' | grep -qx "$container"
}

wait_for_termix() {
  local container="$1" timeout=120 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if is_termix_running "$container"; then
      if docker exec "$container" node -e "fetch('http://127.0.0.1:30001/').then(()=>process.exit(0)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2
    ((elapsed += 2))
  done
  return 1
}

# ================================================================ Background update wrapper
create_background_updater() {
  mkdir -p "$LIB" "$LOG_DIR"
  
  cat > "$BACKGROUND_UPDATER" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# Background update runner with crash recovery
set -uo pipefail

LIB="/usr/local/lib/termix-autoupdate"
LOG_DIR="/var/log/termix-autoupdate"
SCRIPT="$LIB/update.sh"
CONTAINER="$(cat /etc/termix-autoupdate/termix-container 2>/dev/null || echo termix)"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="/var/run/termix-update-state"

mkdir -p "$LOG_DIR"

# Log function
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

log "=== Starting background Termix update ==="
log "Container: $CONTAINER"
log "Script: $SCRIPT"

# Download latest update script if needed
if [ ! -f "$SCRIPT" ]; then
  log "Downloading update script…"
  curl -fsSL "https://raw.githubusercontent.com/alexd-aero/termix-autoupdate/main/update.sh" -o "$SCRIPT" || {
    log "ERROR: Failed to download update script"
    echo "failed" > "$STATE_FILE"
    exit 1
  }
  chmod 755 "$SCRIPT"
fi

# Capture the current Termix PID
PRE_UPDATE_PID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || echo '')"
log "Termix PID before update: $PRE_UPDATE_PID"

# Run the update with error handling
if bash "$SCRIPT" --service --termix-only >> "$LOG_FILE" 2>&1; then
  log "Update completed successfully"
  echo "success" > "$STATE_FILE"
  
  # Restart Termix if it crashed during update
  if [ -n "$PRE_UPDATE_PID" ]; then
    POST_UPDATE_PID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || echo '')"
    if [ "$PRE_UPDATE_PID" != "$POST_UPDATE_PID" ] || ! kill -0 "$PRE_UPDATE_PID" 2>/dev/null; then
      log "Termix process changed or crashed, restarting…"
      docker restart "$CONTAINER" >> "$LOG_FILE" 2>&1 || log "Warning: Failed to restart container"
      
      # Wait for Termix to be fully ready
      for i in {1..60}; do
        if docker exec "$CONTAINER" node -e "fetch('http://127.0.0.1:30001/').then(()=>process.exit(0)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
          log "Termix is back online"
          break
        fi
        sleep 1
      done
    fi
  fi
else
  EXIT_CODE=$?
  log "Update failed with exit code $EXIT_CODE"
  echo "failed" > "$STATE_FILE"
  
  # Try to recover by restarting Termix
  log "Attempting to recover by restarting Termix…"
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    docker restart "$CONTAINER" >> "$LOG_FILE" 2>&1 || log "Warning: Failed to restart container"
    
    for i in {1..60}; do
      if docker exec "$CONTAINER" node -e "fetch('http://127.0.0.1:30001/').then(()=>process.exit(0)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
        log "Termix recovered and is back online"
        break
      fi
      sleep 1
    done
  fi
  
  exit $EXIT_CODE
fi

log "=== Update process completed ==="
WRAPPER_EOF
  
  chmod 755 "$BACKGROUND_UPDATER"
  ok "background updater script created"
}

# ================================================================ Download and setup main update script
setup_update_script() {
  head "Setting up update scripts…"
  
  mkdir -p "$LIB"
  local temp_script
  temp_script="$(mktemp)"
  trap 'rm -f "$temp_script"' RETURN
  
  info "downloading update script…"
  if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script" 2>/dev/null || ! bash -n "$temp_script" 2>/dev/null; then
    fail "failed to download or validate update script"
    return 1
  fi
  
  if ! cmp -s "$temp_script" "$LIB/update.sh" 2>/dev/null; then
    install -m 755 "$temp_script" "$LIB/update.sh"
    ok "update script installed/updated"
  else
    ok "update script is current"
  fi
  
  create_background_updater
}

# ================================================================ Start background update
start_background_update() {
  head "Starting background update…"
  
  local container
  container="$(cat "$CREDS_DIR/termix-container" 2>/dev/null || echo '')"
  [ -n "$container" ] || { fail "no container configured"; return 1; }
  
  # Start the background updater as a detached process
  info "launching background updater (logging to $LOG_DIR)"
  nohup bash "$BACKGROUND_UPDATER" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  
  ok "background update started (PID: $pid)"
  echo
  info "Update is running in the background. Your terminal is free to use."
  info "Monitor progress with:"
  echo "    tail -f $LOG_DIR/update-*.log"
  echo "    journalctl -u termix-autoupdate (if using systemd timer)"
  echo
}

# ================================================================ Main execution
main() {
  head "Termix Background Updater"
  
  ensure_dependencies || exit 1
  acquire_lock || exit 1
  
  collect_credentials || {
    fail "credential setup failed"
    exit 1
  }
  
  setup_update_script || {
    fail "failed to setup update scripts"
    exit 1
  }
  
  start_background_update
  
  ok "setup complete"
  echo
}

# Trap cleanup
trap 'rm -f "$LOCK_FILE" "$PID_FILE"' EXIT

main "$@"
