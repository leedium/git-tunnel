#!/usr/bin/env bash
# Provisions the container on every start, then runs sshd in the foreground.
# Every step is idempotent: keys are created once and reused from /state.
set -euo pipefail

SSH_USER=sshuser
SSH_PORT="${SSH_PORT:-2222}"
TUNNEL_PORT="${TUNNEL_PORT:-2223}"
GIT_HOST="${GIT_HOST:-github.com}"
PROXY_PORT="${PROXY_PORT:-3128}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
PROXY_NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
STATE=/state
SHARE=/usr/local/share/git-tunnel
TEMPLATE="$SHARE/sshd_tunnel.conf"
PROXY_PROFILE=/etc/profile.d/git-tunnel-proxy.sh
NPM_GLOBALRC=/usr/local/etc/npmrc

die() {
  echo "git-tunnel: ERROR: $*" >&2
  exit 1
}

# --- 1. Validate configuration ------------------------------------------------

# PASSWORD_LOGIN=no accepts only client keys, and needs no SSH_PASSWORD.
PASSWORD_AUTH=yes
case "${PASSWORD_LOGIN:-yes}" in
  yes | YES | true | 1 | on) ;;
  no | NO | false | 0 | off) PASSWORD_AUTH=no ;;
  *) die "PASSWORD_LOGIN must be 'yes' or 'no', got '$PASSWORD_LOGIN'." ;;
esac

if [ "$PASSWORD_AUTH" = yes ]; then
  [ -n "${SSH_PASSWORD:-}" ] ||
    die "SSH_PASSWORD is not set. Run ./scripts/setup.sh, or copy .env.example to .env and set it."
  [ "${#SSH_PASSWORD}" -ge 8 ] ||
    die "SSH_PASSWORD must be at least 8 characters."
  case "$SSH_PASSWORD" in
    *$'\n'*) die "SSH_PASSWORD must not contain a newline." ;;
  esac
fi

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_port "$SSH_PORT" || die "SSH_PORT must be a port number, got '$SSH_PORT'."
is_port "$TUNNEL_PORT" || die "TUNNEL_PORT must be a port number, got '$TUNNEL_PORT'."
[ "$TUNNEL_PORT" -ge 1024 ] ||
  die "TUNNEL_PORT must be 1024 or higher, because $SSH_USER is not root."
[ "$TUNNEL_PORT" != "$SSH_PORT" ] || die "TUNNEL_PORT and SSH_PORT must differ."
[[ "$GIT_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "GIT_HOST is not a valid host name: '$GIT_HOST'."

# PROXY_PORT=off disables the HTTP proxy and the SOCKS reverse port.
PROXY_ENABLED=1
case "$PROXY_PORT" in off | OFF | none | 0 | false) PROXY_ENABLED= ;; esac
if [ -n "$PROXY_ENABLED" ]; then
  is_port "$PROXY_PORT" || die "PROXY_PORT must be a port number or 'off', got '$PROXY_PORT'."
  is_port "$SOCKS_PORT" || die "SOCKS_PORT must be a port number, got '$SOCKS_PORT'."
  [ "$PROXY_PORT" -ge 1024 ] && [ "$SOCKS_PORT" -ge 1024 ] ||
    die "PROXY_PORT and SOCKS_PORT must be 1024 or higher."
  [ "$(printf '%s\n' "$SSH_PORT" "$TUNNEL_PORT" "$PROXY_PORT" "$SOCKS_PORT" | sort -u | wc -l)" -eq 4 ] ||
    die "SSH_PORT, TUNNEL_PORT, PROXY_PORT and SOCKS_PORT must all be different."
fi

HOME_DIR="$(getent passwd "$SSH_USER" | cut -d: -f6)"

# --- 2. Login password (from .env, never from the image) ----------------------

if [ "$PASSWORD_AUTH" = yes ]; then
  printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd
else
  # No usable password. "*" (not "!") keeps the account open for key login.
  usermod -p '*' "$SSH_USER"
fi
unset SSH_PASSWORD

# --- 3. sshd host key, persisted so clients never see "host key changed" ------

mkdir -p "$STATE/hostkeys" /run/sshd
chmod 700 "$STATE/hostkeys"
if [ ! -f "$STATE/hostkeys/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "git-tunnel-host" \
    -f "$STATE/hostkeys/ssh_host_ed25519_key"
fi

# --- 4. The user's git key, generated once ------------------------------------

mkdir -p "$STATE/ssh"
if [ ! -f "$STATE/ssh/id_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "git-tunnel@$(hostname)" \
    -f "$STATE/ssh/id_ed25519"
  NEW_KEY=1
fi

# ~/.ssh lives in the state volume.
if [ -e "$HOME_DIR/.ssh" ] && [ ! -L "$HOME_DIR/.ssh" ]; then
  rm -rf "$HOME_DIR/.ssh"
fi
ln -sfn "$STATE/ssh" "$HOME_DIR/.ssh"

# --- 5. ssh client config: this replaces the hand-written entry ---------------

if [ "$GIT_HOST" = "github.com" ]; then
  # Verified against the keys shipped in /etc/ssh/ssh_known_hosts.
  STRICT=yes
else
  # No shipped key for other servers: trust on first use, then pin.
  STRICT=accept-new
fi

cat > "$STATE/ssh/config" <<EOF
# Managed by git-tunnel. Rewritten on every container start.
# Put your own entries in ~/.ssh/config.local instead.
Include ~/.ssh/config.local

# "$GIT_HOST" is reached through the reverse tunnel the client opens on
# 127.0.0.1:$TUNNEL_PORT, so normal git@$GIT_HOST:owner/repo.git URLs just work.
# "github-via-client" is kept as an alias for older remotes.
Host $GIT_HOST github-via-client
    HostName 127.0.0.1
    Port $TUNNEL_PORT
    User git
    HostKeyAlias $GIT_HOST
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking $STRICT
EOF

chown -R "$SSH_USER:$SSH_USER" "$STATE/ssh"
chmod 700 "$STATE/ssh"
chmod 600 "$STATE/ssh/id_ed25519" "$STATE/ssh/config"
chmod 644 "$STATE/ssh/id_ed25519.pub"

# Client keys installed by connect.sh (through tunnel-session add-key).
touch "$STATE/ssh/authorized_keys"
chown "$SSH_USER:$SSH_USER" "$STATE/ssh/authorized_keys"
chmod 600 "$STATE/ssh/authorized_keys"
CLIENT_KEYS="$(grep -c '^[a-z]' "$STATE/ssh/authorized_keys" || true)"

# --- 6. sshd config -----------------------------------------------------------

PERMIT_LISTEN="$TUNNEL_PORT"
[ -z "$PROXY_ENABLED" ] || PERMIT_LISTEN="$TUNNEL_PORT $SOCKS_PORT"
sed -e "s/__SSH_PORT__/$SSH_PORT/g" -e "s/__PERMIT_LISTEN__/$PERMIT_LISTEN/g" \
  -e "s/__PASSWORD_AUTH__/$PASSWORD_AUTH/g" \
  "$TEMPLATE" > /etc/ssh/sshd_config.d/00-git-tunnel.conf
/usr/sbin/sshd -t || die "sshd rejected its configuration (see above)."

# --- 7. Optional git identity -------------------------------------------------

as_user() { HOME="$HOME_DIR" runuser -u "$SSH_USER" -- "$@"; }
[ -z "${GIT_USER_NAME:-}" ] || as_user git config --global user.name "$GIT_USER_NAME"
[ -z "${GIT_USER_EMAIL:-}" ] || as_user git config --global user.email "$GIT_USER_EMAIL"

# --- 8. HTTP proxy for npm and friends, exiting through the client ------------
#
# The client's reverse tunnel offers SOCKS5 on 127.0.0.1:$SOCKS_PORT. npm needs
# an HTTP proxy, so http-to-socks.js bridges the two on 127.0.0.1:$PROXY_PORT.

BASHRC_LINE="[ -r $PROXY_PROFILE ] && . $PROXY_PROFILE"
if [ -n "$PROXY_ENABLED" ]; then
  PROXY_URL="http://127.0.0.1:$PROXY_PORT"

  # Login shells (bash -l) read profile.d. Interactive non-login shells
  # (docker compose exec ... bash) read /etc/bash.bashrc.
  cat > "$PROXY_PROFILE" <<EOF
# Managed by git-tunnel. Rewritten on every container start.
export HTTP_PROXY=$PROXY_URL HTTPS_PROXY=$PROXY_URL
export http_proxy=$PROXY_URL https_proxy=$PROXY_URL
export NO_PROXY=$PROXY_NO_PROXY no_proxy=$PROXY_NO_PROXY
EOF
  grep -qxF "$BASHRC_LINE" /etc/bash.bashrc || echo "$BASHRC_LINE" >> /etc/bash.bashrc

  # npm's global config, so npm uses the proxy even without a shell
  # (docker compose exec tunnel npm install). It does not touch any .npmrc
  # that carries your registry credentials.
  mkdir -p "$(dirname "$NPM_GLOBALRC")"
  cat > "$NPM_GLOBALRC" <<EOF
; Managed by git-tunnel. Rewritten on every container start.
proxy=$PROXY_URL
https-proxy=$PROXY_URL
noproxy=$PROXY_NO_PROXY
EOF

  # Run the shim unprivileged and restart it if it ever exits.
  (
    while true; do
      PROXY_PORT="$PROXY_PORT" SOCKS_PORT="$SOCKS_PORT" \
        runuser -u nobody -- node "$SHARE/http-to-socks.js" || true
      sleep 2
    done
  ) &
else
  rm -f "$PROXY_PROFILE" "$NPM_GLOBALRC"
fi

# --- 9. Tell the operator what to do next -------------------------------------

echo "------------------------------------------------------------------------"
echo "git-tunnel is ready. sshd on port $SSH_PORT, tunnel port $TUNNEL_PORT -> $GIT_HOST:22"
if [ -n "$PROXY_ENABLED" ]; then
  echo "HTTP proxy for npm on 127.0.0.1:$PROXY_PORT -> client (SOCKS port $SOCKS_PORT)"
else
  echo "HTTP proxy is off (PROXY_PORT=off)"
fi
echo
if [ -n "${NEW_KEY:-}" ]; then
  echo "A NEW git key was generated. Add this public key to $GIT_HOST"
  echo "(GitHub: Settings -> SSH and GPG keys, or a repo's Deploy keys):"
else
  echo "Public git key (already generated, add it to $GIT_HOST if you have not):"
fi
echo
cat "$STATE/ssh/id_ed25519.pub"
echo
HOST_FP="$(ssh-keygen -l -f "$STATE/hostkeys/ssh_host_ed25519_key.pub" | awk '{print $2}')"
echo "Then on the client:"
echo "  ./scripts/connect.sh <this-host> --fingerprint $HOST_FP"
echo "The fingerprint identifies this container, so the client knows it is"
echo "talking to the right machine before any password is typed."
echo
if [ "$PASSWORD_AUTH" = yes ]; then
  echo "Client keys installed: $CLIENT_KEYS. Password login is on. Once your clients have"
  echo "connected once, set PASSWORD_LOGIN=no in .env to accept keys only."
else
  echo "Client keys installed: $CLIENT_KEYS. Password login is off."
  [ "$CLIENT_KEYS" -gt 0 ] || {
    echo "WARNING: no client key is installed, so nothing can log in. Add one with:"
    echo "  docker exec -i -u sshuser git-tunnel tunnel-session add-key < client_key.pub"
  }
fi
echo "To use git on this Docker host too:  ./scripts/host-setup.sh"
echo "------------------------------------------------------------------------"

exec /usr/sbin/sshd -D -e
