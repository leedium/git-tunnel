#!/usr/bin/env bash
# Lets git on the Docker host use the container's tunnel, so you do not have to
# work inside the container. Run it once on the machine that runs the container.
#
#   ./scripts/host-setup.sh [options]
#
# It adds a URL alias to your global git config. Remotes written as
#   git@github-tunnel:owner/repo.git
# then run the container's ssh through "docker exec", which uses the
# container's git key and reaches the git server through the client's tunnel.
# Ordinary git@github.com: remotes on this machine are not changed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: host-setup.sh [options]

Options:
  --alias NAME          host name to use in git URLs       (default github-tunnel)
  --container NAME      name of the running container      (default git-tunnel)
  --git-host HOST       git server the tunnel points at    (default github.com,
                        or GIT_HOST from the repo's .env)
  --remove              remove the alias from your global git config
  -h, --help            show this help

After setup:
  git clone git@github-tunnel:owner/repo.git
  git remote set-url origin git@github-tunnel:owner/repo.git   # existing clone
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

die() { echo "host-setup.sh: $*" >&2; exit 1; }

ALIAS=github-tunnel
CONTAINER=git-tunnel
GIT_HOST="$(env_value GIT_HOST)"
GIT_HOST="${GIT_HOST:-github.com}"
REMOVE=

need_value() { [ $# -ge 2 ] || { echo "host-setup.sh: $1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --alias) need_value "$@"; ALIAS="$2"; shift 2 ;;
    --container) need_value "$@"; CONTAINER="$2"; shift 2 ;;
    --git-host) need_value "$@"; GIT_HOST="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "host-setup.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

# These values end up inside a command line that git splits on spaces, so keep
# them to plain name characters.
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ "$ALIAS" =~ $name_re ]] || die "--alias is not a valid host name: '$ALIAS'"
[[ "$CONTAINER" =~ $name_re ]] || die "--container is not a valid container name: '$CONTAINER'"
[[ "$GIT_HOST" =~ $name_re ]] || die "--git-host is not a valid host name: '$GIT_HOST'"
[ "$ALIAS" != "$GIT_HOST" ] ||
  die "the alias must differ from the git host, or every $GIT_HOST remote would be rerouted"

command -v git >/dev/null 2>&1 || die "git is not installed on this machine"

# Remove every url.*.insteadOf entry that maps one of our two alias prefixes,
# whatever command it pointed at. Makes setup repeatable and --remove complete.
remove_alias() {
  local rec key value section
  while IFS= read -r -d '' rec; do
    key="${rec%%$'\n'*}"
    value="${rec#*$'\n'}"
    case "$value" in
      "$ALIAS:" | "git@$ALIAS:") ;;
      *) continue ;;
    esac
    git config --global --unset-all "$key" "^${value//./\\.}\$" || true
    section="${key%.*}"
    if ! git config --global --get-regexp "^${section//./\\.}\\." >/dev/null 2>&1; then
      git config --global --remove-section "$section" 2>/dev/null || true
    fi
  done < <(git config --global -z --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true)
}

if [ -n "$REMOVE" ]; then
  remove_alias
  # Take back the ext permission only when no other alias still needs it.
  if ! git config --global --get-regexp '^url\.ext::.*\.insteadof$' >/dev/null 2>&1; then
    git config --global --unset-all protocol.ext.allow 2>/dev/null || true
  fi
  echo "Removed the '$ALIAS' alias from your global git config."
  echo "Remotes that still use git@$ALIAS: will stop working until you change them back."
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker is not installed on this machine"

# git's ext:: transport runs this command and speaks the git protocol over its
# stdin and stdout. %S becomes git-upload-pack or git-receive-pack, and the
# repository path from the URL is appended after the trailing space.
BASE="ext::docker exec -i -u sshuser $CONTAINER ssh git@$GIT_HOST %S "

remove_alias
git config --global --add "url.$BASE.insteadOf" "git@$ALIAS:"
git config --global --add "url.$BASE.insteadOf" "$ALIAS:"

# git refuses the ext transport unless it is allowed. "user" permits it only
# for URLs you give git yourself, never for submodules or redirects, which is
# the level git already applies to local file URLs.
git config --global protocol.ext.allow user

echo "Added the '$ALIAS' alias to your global git config."
echo "  git@$ALIAS:owner/repo.git -> container '$CONTAINER' -> tunnel -> $GIT_HOST"
echo

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
  echo "Note: container '$CONTAINER' is not running. Start it with: docker compose up -d"
  echo
fi

cat <<EOF
Use it from any directory on this machine, while the client tunnel is open:
  git ls-remote git@$ALIAS:owner/repo.git                      # quick test
  git clone git@$ALIAS:owner/repo.git
  git remote set-url origin git@$ALIAS:owner/repo.git          # existing clone

GitHub sees the container's key. Print it with: docker exec $CONTAINER show-key
Undo with: ./scripts/host-setup.sh --remove
EOF
