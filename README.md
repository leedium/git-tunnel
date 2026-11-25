# git-tunnel

A Docker container that can use GitHub even though it has no route to GitHub.
A client machine that *can* reach GitHub opens a reverse SSH tunnel into the
container, and git inside the container talks to GitHub through it.

The same tunnel also carries `npm install` and other https traffic, for
registries that block the container's IP address but accept the client's.

No ssh config or proxy setting is written by hand. The container configures
itself on start.

```
   container (blocked or no access)           client Mac (has access)
  ┌───────────────────────────────┐          ┌──────────────────────────┐
  │ git clone git@github.com:...  │   ssh    │  ./scripts/connect.sh    │
  │        ▼                      │◀─────────│  logs in on port 2222    │
  │ 127.0.0.1:2223 ═══════════════╪══════════╪═▶ github.com:22          │
  │                               │          │                          │
  │ npm install                   │          │                          │
  │        ▼  HTTP proxy          │          │                          │
  │ 127.0.0.1:3128  (Node shim)   │          │                          │
  │        ▼  SOCKS5              │          │                          │
  │ 127.0.0.1:1080 ═══════════════╪══════════╪═▶ registry.npmjs.org:443 │
  └───────────────────────────────┘  tunnel  └──────────────────────────┘
```

## Quick start

**On the Docker host**

```bash
cp .env.example .env        # then set SSH_PASSWORD (8+ characters)
docker compose up -d --build
docker compose logs tunnel  # prints the container's public git key
```

Add the printed public key to GitHub, either under *Settings → SSH and GPG
keys* for your account or as a *Deploy key* on one repository.

**On the client Mac**

```bash
./scripts/connect.sh <docker-host-ip>
```

Enter the `SSH_PASSWORD`. Leave it running. Use `localhost` as the host when
Docker runs on the same Mac.

**Use git in the container**

```bash
docker compose exec -u sshuser -w /home/sshuser/work tunnel bash
ssh -T git@github.com                       # "Hi <you>! You've successfully authenticated"
git clone git@github.com:owner/repo.git     # ordinary URLs, nothing special
```

Clones land in `./workspace` on the Docker host.

**Use npm in the container**

```bash
npm install        # nothing to configure, it already uses the proxy
```

Keep your registry credentials in the project or user `.npmrc` as usual. The
proxy settings live in npm's separate global config and do not touch them.

## npm and other web traffic through the client

npm can only talk to an HTTP proxy, and an ssh tunnel can only offer SOCKS.
The container bridges the two:

1. `connect.sh` opens a second reverse port. The ssh client on the Mac acts as
   a SOCKS5 proxy for it, so nothing extra is installed on the client.
2. `docker/http-to-socks.js`, a dependency-free Node script, listens as an HTTP
   proxy on `127.0.0.1:3128` and re-dials every request through that SOCKS port.
3. The entrypoint points npm at the proxy, and sets `HTTP_PROXY` and
   `HTTPS_PROXY` in shells so curl, pip, yarn, pnpm and git over https use it too.

Host names are resolved on the client, so the container needs no DNS for them.

**The client decides where the container may go.** By default only port 443 is
allowed, to any host. Widen or narrow it with `--allow`:

```bash
./scripts/connect.sh <host> --allow 'registry.npmjs.org:443' --allow 'npm.pkg.github.com:443'
./scripts/connect.sh <host> --allow '*:443' --allow '*:80'    # also plain http
./scripts/connect.sh <host> --no-proxy                        # git only
```

To turn the feature off in the container, set `PROXY_PORT=off` in `.env`. To
send some hosts directly instead of through the client, set `NO_PROXY`.

## Configuration

Everything is set in `.env`.

| Variable | Default | Purpose |
|---|---|---|
| `SSH_PASSWORD` | required | Password the client uses to log in as `sshuser`. Minimum 8 characters. |
| `SSH_PORT` | `2222` | Port sshd listens on, published on the Docker host. |
| `TUNNEL_PORT` | `2223` | Port inside the container the tunnel listens on. Never published. |
| `GIT_HOST` | `github.com` | Git server reached through the client. |
| `PROXY_PORT` | `3128` | HTTP proxy inside the container for npm and web traffic. `off` disables it. |
| `SOCKS_PORT` | `1080` | Port inside the container for the client's reverse SOCKS tunnel. Never published. |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | Hosts that bypass the proxy. |
| `NODE_VERSION` | `22` | Node.js version in the image. Needs a rebuild. |
| `WORKSPACE_DIR` | `./workspace` | Host folder mounted at `/home/sshuser/work`. |
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | empty | Optional git identity inside the container. |
| `SSH_UID` | `1000` | UID of `sshuser`. Linux hosts only. Needs a rebuild. |

`connect.sh` reads `SSH_PORT`, `TUNNEL_PORT`, `GIT_HOST`, `SOCKS_PORT` and
`PROXY_PORT` from a `.env` next to the repo when one exists. Otherwise pass
`--port`, `--tunnel-port`, `--git-host`, `--socks-port` or `--no-proxy`. The client does not need the whole repo, only the script.

To add tools to the image, edit the `apt-get install` list in the `Dockerfile`
and run `docker compose up -d --build`.

## What the container sets up for you

On every start `docker/entrypoint.sh`:

1. Sets the `sshuser` password from `.env`. It is never stored in the image.
2. Creates the sshd host key once, in the `tunnel-state` volume.
3. Creates an ed25519 git key once, in the same volume, and prints the public half.
4. Writes `~/.ssh/config` so `github.com` and the alias `github-via-client`
   both resolve to the tunnel at `127.0.0.1:2223`.
5. Verifies GitHub against its published host keys, shipped in the image.

Your own ssh entries go in `~/.ssh/config.local` inside the container. That
file is in the volume and is never overwritten.

## Security notes

- The tunnel, SOCKS and proxy ports are bound to the container's loopback. Other
  machines on the network cannot use them, and Docker does not publish them.
- sshd allows one user, the two reverse ports, and no other forwarding.
- The SOCKS port lets code in the container, including npm install scripts,
  open connections from the client machine. The client limits the destinations
  with `--allow`. The default of `*:443` still reaches https services on the
  client's own network, so name the registries explicitly if that matters.
- Password login is enabled by design. Choose a long password, and only publish
  `SSH_PORT` on networks you trust. To use a key instead, append your public
  key to `/state/ssh/authorized_keys` in the container.
- The private git key stays in the `tunnel-state` volume. `docker compose down -v`
  deletes it, and you would then add a new public key to GitHub.
- `SSH_PASSWORD` is visible to anyone who can run `docker inspect` on the host.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Container keeps restarting | `SSH_PASSWORD` is missing or too short. See `docker compose logs tunnel`. |
| `Connection refused` on `127.0.0.1 port 2223` inside the container | The client tunnel is not running. Start `connect.sh`. |
| `Permission denied (publickey)` from GitHub | The tunnel works, but the public key is not on GitHub yet. Run `docker compose exec tunnel show-key`. |
| `remote port forwarding failed` on the client | Another tunnel already holds the port, a port differs from the container's `.env`, or the container has `PROXY_PORT=off` and the client did not pass `--no-proxy`. |
| npm fails with `502 Bad Gateway` | The client tunnel is not running, or the destination is not covered by `--allow`. `docker compose logs tunnel` names the refused host and port. |
| npm still gets `403` from the registry | The request now leaves from the client. Check that the client's own IP is accepted, and that `.npmrc` credentials are present in the container. |
| `cannot reach github.com on port 22` on the client | The client itself has no route to GitHub. The tunnel needs one. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` on the client | The state volume was recreated. Run `ssh-keygen -R '[<host>]:2222'`. |

## Commands

```bash
docker compose up -d --build     # build and start
docker compose logs -f tunnel    # watch sshd and see the public key
docker compose exec tunnel show-key
docker compose down              # stop, keep keys
docker compose down -v           # stop and delete keys
```
