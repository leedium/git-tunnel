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
  --user NAME           login user on the container         (default sshuser)
  -h, --help            show this help
  -- <ssh options>      anything after -- is passed to ssh unchanged,
                        for example: -- -i ~/.ssh/id_ed25519

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

echo "Connecting to $SSH_USER@$HOST:$PORT"
echo "  git:   container port $TUNNEL_PORT -> $GIT_HOST:22"
if [ -n "$PROXY" ]; then
  echo "  proxy: container SOCKS port $SOCKS_PORT -> this machine -> ${ALLOW[*]}"
else
  echo "  proxy: off"
fi
echo "Enter the SSH_PASSWORD from the container's .env when asked."

# -N                      no remote shell, only the forwards
# -R port:host:22         container:TUNNEL_PORT -> (this machine) -> GIT_HOST:22
# ExitOnForwardFailure    fail loudly if a port cannot be opened
# ServerAlive*            notice a dead link within about 90 seconds
# LocalCommand            prints once the connection is really up
exec ssh -p "$PORT" -N \
  -R "$TUNNEL_PORT:$GIT_HOST:22" \
  ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o PermitLocalCommand=yes \
  -o LocalCommand="echo 'Tunnel open. Leave this running. Ctrl-C to close.'" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  "$SSH_USER@$HOST"
