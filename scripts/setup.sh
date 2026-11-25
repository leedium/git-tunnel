#!/usr/bin/env bash
# One-command setup on the Docker host.
#
#   ./scripts/setup.sh [options]
#
# Creates .env with a generated password if there is none, builds and starts
# the container, sets up the git alias for this host, and prints the two things
# left to do: add the public key to GitHub, and run one command on the client.
# Safe to run again: it never overwrites an existing .env or key.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup.sh [options]

Options:
  --no-host-git         do not add the git@github-tunnel: alias to this
                        machine's global git config (scripts/host-setup.sh)
  --host ADDRESS        address the client should use to reach this machine
                        (default: detected)
  -h, --help            show this help
EOF
}

die() { echo "setup.sh: $*" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER=git-tunnel
HOST_GIT=1
ADDRESS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-host-git) HOST_GIT=; shift ;;
    --host) [ $# -ge 2 ] || die "--host needs a value"; ADDRESS="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "setup.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Read one KEY=value from .env without executing the file.
env_value() {
  local key="$1"
  [ -f "$REPO/.env" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$REPO/.env" | tail -n 1 |
    sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/'
}

command -v docker >/dev/null 2>&1 || die "docker is not installed."
docker compose version >/dev/null 2>&1 || die "'docker compose' is not available."
docker info >/dev/null 2>&1 || die "the Docker daemon is not running."

cd "$REPO"

# --- 1. .env with a generated password ----------------------------------------

NEW_PASSWORD=""
if [ ! -f .env ]; then
  NEW_PASSWORD="$(head -c 15 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  (
    umask 077
    sed "s/^SSH_PASSWORD=.*/SSH_PASSWORD=$NEW_PASSWORD/" .env.example > .env
  )
  echo "Created .env with a generated password."
else
  chmod 600 .env
  echo "Using the existing .env."
fi

# --- 2. Build and start -------------------------------------------------------

docker compose up -d --build

echo "Waiting for the container..."
READY=""
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" sh -c \
    'test -s /state/ssh/id_ed25519.pub && test -s /state/hostkeys/ssh_host_ed25519_key.pub && test -f /etc/ssh/sshd_config.d/00-git-tunnel.conf' \
    >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done
if [ -z "$READY" ]; then
  docker compose logs --tail 20 tunnel >&2 || true
  die "the container did not start. See the log above."
fi

GIT_KEY="$(docker exec "$CONTAINER" show-key)"
FINGERPRINT="$(docker exec "$CONTAINER" ssh-keygen -l -f /state/hostkeys/ssh_host_ed25519_key.pub | awk '{print $2}')"

# --- 3. git on this host ------------------------------------------------------

if [ -n "$HOST_GIT" ]; then
  if command -v git >/dev/null 2>&1; then
    "$REPO/scripts/host-setup.sh" >/dev/null
    HOST_GIT_DONE=1
  else
    echo "git is not installed on this machine, skipping the host alias."
  fi
fi

# --- 4. What the client has to run --------------------------------------------

if [ -z "$ADDRESS" ]; then
  case "$(env_value SSH_BIND)" in
    127.* | localhost | ::1) ADDRESS=localhost ;;
  esac
fi
if [ -z "$ADDRESS" ]; then
  if command -v ipconfig >/dev/null 2>&1 && command -v route >/dev/null 2>&1; then
    # macOS: address of the interface that holds the default route.
    IFACE="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
    [ -z "$IFACE" ] || ADDRESS="$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)"
  elif command -v ip >/dev/null 2>&1; then
    ADDRESS="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  fi
fi
ADDRESS="${ADDRESS:-<this-machine-ip>}"

# The client usually has only connect.sh, not this .env, so spell out anything
# that differs from the script's defaults.
CLIENT_ARGS="$ADDRESS --fingerprint $FINGERPRINT"
add_arg() { # .env key, default, option
  local v
  v="$(env_value "$1")"
  [ -z "$v" ] || [ "$v" = "$2" ] || CLIENT_ARGS="$CLIENT_ARGS $3 $v"
}
add_arg SSH_PORT 2222 --port
add_arg TUNNEL_PORT 2223 --tunnel-port
add_arg GIT_HOST github.com --git-host
case "$(env_value PROXY_PORT)" in
  off | OFF | none | 0 | false) CLIENT_ARGS="$CLIENT_ARGS --no-proxy" ;;
  *) add_arg SOCKS_PORT 1080 --socks-port ;;
esac

GIT_HOST="$(env_value GIT_HOST)"
GIT_HOST="${GIT_HOST:-github.com}"

cat <<EOF

========================================================================
git-tunnel is running. Two things are left.

1. Add this public key to $GIT_HOST, if you have not already
   (GitHub: Settings -> SSH and GPG keys, or a repository's Deploy keys):

$GIT_KEY

2. On the client machine (the one that can reach $GIT_HOST), copy
   scripts/connect.sh over and run:

   bash connect.sh $CLIENT_ARGS

EOF

if [ -n "$NEW_PASSWORD" ]; then
  cat <<EOF
   It asks for this password once, then uses a key:

   $NEW_PASSWORD

EOF
else
  cat <<EOF
   The first run asks for SSH_PASSWORD from .env once, then uses a key.

EOF
fi

cat <<EOF
   When every client has connected once, you can set PASSWORD_LOGIN=no in
   .env and run this script again, so only those keys are accepted.

Then use git:
EOF
if [ -n "${HOST_GIT_DONE:-}" ]; then
  echo "   git clone git@github-tunnel:owner/repo.git        # on this machine, any directory"
fi
cat <<EOF
   docker compose exec -u sshuser -w /home/sshuser/work tunnel bash   # or inside the container
========================================================================
EOF
