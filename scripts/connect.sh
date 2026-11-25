#!/usr/bin/env bash
# Opens the reverse tunnel from this Mac to the git-tunnel container, so the
# container can reach the git server, and npm registries, through this machine.
#
#   ./scripts/connect.sh <container-host> [options]
#
# Leave it running. Ctrl-C closes the tunnel.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: connect.sh <container-host> [options]

  <container-host>      IP or name of the machine running the container
                        (use "localhost" if Docker runs on this Mac)

Options:
  --port N              sshd port on the container host     (default 2222)
  --tunnel-port N       git tunnel port in the container    (default 2223)
  --git-host HOST       git server to forward to            (default github.com)
  --socks-port N        SOCKS port in the container, used by its HTTP proxy
                        for npm install and other web traffic (default 1080)
  --allow HOST:PORT     destination the container may reach through the proxy.
                        Repeatable. "*" is a wildcard, "any" allows everything.
                        (default *:443, which is https to any host)
  --no-proxy            git only: do not open the SOCKS port
  --fingerprint FP      SHA256:... fingerprint of the container, as printed by
                        setup.sh and the container log. Checked before the
                        first connection, so there is no trust prompt.
  --key PATH            private key this machine logs in with
                        (default ~/.ssh/git-tunnel_ed25519, created if missing)
  --no-key              do not use a key: ask for the password every time
  --user NAME           login user on the container         (default sshuser)
  -h, --help            show this help
  -- <ssh options>      anything after -- is passed to ssh unchanged,
                        for example: -- -i ~/.ssh/id_ed25519

The first run asks for the container's SSH_PASSWORD once and installs this
machine's key in the container. Later runs do not ask.

Defaults are read from the .env next to this repo when it exists, so a
client that has the same checkout needs no options at all.
EOF
}

# Read one KEY=value from the repo's .env without executing the file.
env_value() {
  local file key
  file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
  key="$1"
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n 1 |
    sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/'
}

PORT="$(env_value SSH_PORT)"
TUNNEL_PORT="$(env_value TUNNEL_PORT)"
GIT_HOST="$(env_value GIT_HOST)"
SOCKS_PORT="$(env_value SOCKS_PORT)"
PROXY_PORT="$(env_value PROXY_PORT)"
PORT="${PORT:-2222}"
TUNNEL_PORT="${TUNNEL_PORT:-2223}"
GIT_HOST="${GIT_HOST:-github.com}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SSH_USER=sshuser
HOST=""
PROXY=1
ALLOW=()
EXTRA=()
KEY="$HOME/.ssh/git-tunnel_ed25519"
USE_KEY=1
FINGERPRINT=""

die() { echo "connect.sh: $*" >&2; exit 1; }

# The container refuses the SOCKS port when its proxy is switched off.
case "$PROXY_PORT" in off | OFF | none | 0 | false) PROXY= ;; esac

need_value() { [ $# -ge 2 ] || { echo "connect.sh: $1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port) need_value "$@"; PORT="$2"; shift 2 ;;
    --tunnel-port) need_value "$@"; TUNNEL_PORT="$2"; shift 2 ;;
    --git-host) need_value "$@"; GIT_HOST="$2"; shift 2 ;;
    --socks-port) need_value "$@"; SOCKS_PORT="$2"; PROXY=1; shift 2 ;;
    --allow) need_value "$@"; ALLOW+=("$2"); shift 2 ;;
    --no-proxy) PROXY=; shift ;;
    --fingerprint) need_value "$@"; FINGERPRINT="$2"; shift 2 ;;
    --key) need_value "$@"; KEY="$2"; USE_KEY=1; shift 2 ;;
    --no-key) USE_KEY=; shift ;;
    --user) need_value "$@"; SSH_USER="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    --) shift; EXTRA=("$@"); break ;;
    -*) echo "connect.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$HOST" ] || { echo "connect.sh: only one host allowed" >&2; exit 2; }
      HOST="$1"; shift ;;
  esac
done

if [ -z "$HOST" ]; then
  usage >&2
  exit 2
fi

for n in "$PORT" "$TUNNEL_PORT" "$SOCKS_PORT"; do
  case "$n" in
    '' | *[!0-9]*) echo "connect.sh: '$n' is not a port number" >&2; exit 2 ;;
  esac
done

# This machine must be able to reach the git server, or the tunnel is useless.
if command -v nc >/dev/null 2>&1; then
  if ! nc -z -w 5 "$GIT_HOST" 22 >/dev/null 2>&1; then
    echo "connect.sh: this machine cannot reach $GIT_HOST on port 22." >&2
    echo "The tunnel forwards through this machine, so that has to work first." >&2
    exit 1
  fi
fi

# Reverse SOCKS: "-R port" with no destination makes this ssh client act as a
# SOCKS proxy for the container. PermitRemoteOpen limits where it may connect,
# so code running in the container cannot roam this machine's network.
PROXY_ARGS=()
if [ -n "$PROXY" ]; then
  [ "${#ALLOW[@]}" -gt 0 ] || ALLOW=("*:443")
  PROXY_ARGS=(-R "$SOCKS_PORT" -o "PermitRemoteOpen=${ALLOW[*]}")
fi

# ssh options shared by every connection this script makes.
BASE=(-p "$PORT" -o ConnectTimeout=15 ${EXTRA[@]+"${EXTRA[@]}"})

# --- Check the container's identity before trusting it ------------------------
#
# Without --fingerprint, ssh asks its usual "are you sure" question the first
# time. With it, the key is fetched, compared, and recorded only on a match.
if [ -n "$FINGERPRINT" ]; then
  if [ "$PORT" = 22 ]; then KNOWN_NAME="$HOST"; else KNOWN_NAME="[$HOST]:$PORT"; fi
  if ! ssh-keygen -F "$KNOWN_NAME" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    SCANNED="$(ssh-keyscan -T 10 -p "$PORT" -t ed25519 "$HOST" 2>/dev/null || true)"
    [ -n "$SCANNED" ] ||
      die "cannot reach $HOST on port $PORT. Is the container running, and the port open?"
    GOT="$(printf '%s\n' "$SCANNED" | ssh-keygen -l -f - | awk '{print $2}')"
    if [ "$GOT" != "$FINGERPRINT" ]; then
      echo "connect.sh: the machine at $HOST:$PORT is NOT the expected container." >&2
      echo "  expected $FINGERPRINT" >&2
      echo "  got      $GOT" >&2
      echo "Not connecting. Check the host address, or get the current fingerprint" >&2
      echo "from 'docker compose logs tunnel' on the Docker host." >&2
      exit 1
    fi
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    printf '%s\n' "$SCANNED" >> "$HOME/.ssh/known_hosts"
    echo "Container identity verified."
  fi
fi

# --- Log in with a key, installing it on the first run -------------------------
#
# The key is dedicated to this tunnel and has no passphrase. In the container
# it can only open the tunnel ports: the login has no shell.
KEY_ARGS=()
NEED_PASSWORD=1
if [ -n "$USE_KEY" ]; then
  if [ ! -f "$KEY" ]; then
    mkdir -p "$(dirname "$KEY")"
    ssh-keygen -q -t ed25519 -N '' -C "git-tunnel-client@$(hostname -s 2>/dev/null || echo client)" -f "$KEY"
    echo "Created a key for this machine: $KEY"
  fi
  [ -f "$KEY.pub" ] || die "$KEY.pub is missing. Delete $KEY to have a new pair created."
  KEY_ARGS=(-i "$KEY" -o IdentitiesOnly=yes)

  if ssh "${BASE[@]}" "${KEY_ARGS[@]}" -o BatchMode=yes "$SSH_USER@$HOST" ping >/dev/null 2>&1; then
    NEED_PASSWORD=
  else
    echo "First connection from this machine: installing its key in the container."
    echo "Enter the SSH_PASSWORD from the container's .env. You will not be asked again."
    if ssh "${BASE[@]}" -o PubkeyAuthentication=no "$SSH_USER@$HOST" add-key < "$KEY.pub"; then
      NEED_PASSWORD=
    else
      echo "connect.sh: could not install the key. Continuing with the password." >&2
      echo "(If the container is older than this script, rebuild it: docker compose up -d --build)" >&2
    fi
  fi
fi

echo "Connecting to $SSH_USER@$HOST:$PORT"
echo "  git:   container port $TUNNEL_PORT -> $GIT_HOST:22"
if [ -n "$PROXY" ]; then
  echo "  proxy: container SOCKS port $SOCKS_PORT -> this machine -> ${ALLOW[*]}"
else
  echo "  proxy: off"
fi
[ -z "$NEED_PASSWORD" ] || echo "Enter the SSH_PASSWORD from the container's .env when asked."

# -N                      no remote shell, only the forwards
# -R port:host:22         container:TUNNEL_PORT -> (this machine) -> GIT_HOST:22
# ExitOnForwardFailure    fail loudly if a port cannot be opened
# ServerAlive*            notice a dead link within about 90 seconds
# LocalCommand            prints once the connection is really up
exec ssh "${BASE[@]}" -N \
  ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
  -R "$TUNNEL_PORT:$GIT_HOST:22" \
  ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o PermitLocalCommand=yes \
  -o LocalCommand="echo 'Tunnel open. Leave this running. Ctrl-C to close.'" \
  "$SSH_USER@$HOST"
