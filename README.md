# git-tunnel

A Docker container that can use GitHub even though it has no route to GitHub.
A client machine that *can* reach GitHub opens a reverse SSH tunnel into the
container, and git inside the container talks to GitHub through it.

The same tunnel also carries `npm install` and other https traffic, for
registries that block the container's IP address but accept the client's.

No ssh config or proxy setting is written by hand. The container configures
itself on start.

```
   Docker host (optional, see "Git on the Docker host")
  ┌───────────────────────────────┐
  │ git clone git@github-tunnel:… │
  └───────────────┬───────────────┘
                  │  docker exec: runs the container's ssh
                  ▼
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
./scripts/setup.sh
```

It creates `.env` with a generated password, builds and starts the container,
sets up [git on the Docker host](#git-on-the-docker-host), and prints:

- the container's public git key. Add it to GitHub, either under *Settings →
  SSH and GPG keys* for your account or as a *Deploy key* on one repository.
  A deploy key or a separate machine account limits what the container can reach.
- the exact command for the client, with this machine's address and the
  container's fingerprint filled in, and the password.

**On the client Mac**

Copy `scripts/connect.sh` to the client and run the command `setup.sh` printed:

```bash
bash connect.sh <docker-host-ip> --fingerprint SHA256:...
```

The first run asks for the password once and installs a key for this client.
Later runs ask for nothing. Leave it running. Use `localhost` as the host when
Docker runs on the same Mac.

Running it as `bash connect.sh` works even when the copy lost its execute bit,
which happens with AirDrop, a file share or a download. `./connect.sh` then
answers `permission denied`; `chmod +x connect.sh` fixes that.

<details>
<summary>Manual setup, without setup.sh</summary>

```bash
cp .env.example .env        # then set SSH_PASSWORD (8+ characters)
docker compose up -d --build
docker compose logs tunnel  # prints the public git key and the client command
./scripts/host-setup.sh     # optional: git on the Docker host
```

</details>

**Use git in the container**

```bash
docker compose exec -u sshuser -w /home/sshuser/work tunnel bash
ssh -T git@github.com                       # "Hi <you>! You've successfully authenticated"
git clone git@github.com:owner/repo.git     # ordinary URLs, nothing special
```

Clones land in `./workspace` on the Docker host.

**Or use git on the Docker host, without entering the container**

```bash
./scripts/host-setup.sh                               # once, on the Docker host
git clone git@github-tunnel:owner/repo.git            # from any directory
```

See [Git on the Docker host](#git-on-the-docker-host).

**Use npm in the container**

```bash
npm install        # nothing to configure, it already uses the proxy
```

Keep your registry credentials in the project or user `.npmrc` as usual. The
proxy settings live in npm's separate global config and do not touch them.

## Git on the Docker host

You do not have to work inside the container. Run this once on the machine
that runs it:

```bash
./scripts/host-setup.sh
```

After that, any remote on the host written with the host name `github-tunnel`
goes host → container → tunnel → client → GitHub:

```bash
git ls-remote git@github-tunnel:owner/repo.git                 # quick test
git clone git@github-tunnel:owner/repo.git
git remote set-url origin git@github-tunnel:owner/repo.git     # existing clone
```

Ordinary `git@github.com:` remotes on the host are left alone, so the tunnel
is used only where you ask for it. The client tunnel must be open, as before.

How it works: the script adds a URL alias to your global git config. Git
expands `git@github-tunnel:` into a `docker exec` that runs the container's
own `ssh`, so the container's key, its ssh config and its pinned GitHub host
keys are reused. No extra port is published.

Things to know:

- GitHub sees the container's key, the same one you already added.
- Commits made on the host use the host's `user.name` and `user.email`.
- The alias uses git's `ext` transport, which git blocks by default. The script
  sets `protocol.ext.allow=user`, which allows it only for URLs you give git
  yourself, not for submodules or redirects.
- Submodules and git-lfs do not work through the alias.
- `./scripts/host-setup.sh --remove` undoes both settings. `--alias NAME` picks
  a different host name.

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
| `SSH_PASSWORD` | required | Password a client uses the first time it connects, before its key is installed. Minimum 8 characters. `setup.sh` generates one. Not needed when `PASSWORD_LOGIN=no`. |
| `PASSWORD_LOGIN` | `yes` | Set to `no` to accept client keys only. Do this once your clients have connected once. |
| `SSH_BIND` | `0.0.0.0` | Address on the Docker host that sshd is published on. `127.0.0.1` when the client is the same machine. |
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
`--port`, `--tunnel-port`, `--git-host`, `--socks-port` or `--no-proxy`. The
client does not need the whole repo, only the script. `setup.sh` prints the
options that differ from the defaults.

## Client login

- **Key.** On its first run `connect.sh` creates `~/.ssh/git-tunnel_ed25519` on
  the client (no passphrase, used only for this tunnel), asks for the password
  once and installs the public half in the container. `--key PATH` uses another
  key, `--no-key` keeps asking for the password.
- **Fingerprint.** `--fingerprint SHA256:...` makes `connect.sh` check that the
  machine it reached is your container before anything is typed. Without it,
  ssh asks its usual first-connection question. The fingerprint is printed by
  `setup.sh` and in `docker compose logs tunnel`.
- **Keys only.** When every client has connected once, set `PASSWORD_LOGIN=no`
  in `.env` and run `docker compose up -d`. To add a client after that, without
  a password, run this on the Docker host with the client's public key:

  ```bash
  docker exec -i -u sshuser git-tunnel tunnel-session add-key < git-tunnel_ed25519.pub
  ```

- **No shell.** The ssh login can open the tunnel ports and nothing else. Work
  inside the container goes through `docker compose exec`.

To add tools to the image, edit the `apt-get install` list in the `Dockerfile`
and run `docker compose up -d --build`.

## What the container sets up for you

On every start `docker/entrypoint.sh`:

1. Sets the `sshuser` password from `.env`, or disables it when
   `PASSWORD_LOGIN=no`. It is never stored in the image.
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
- sshd allows one user, the two reverse ports, and no other forwarding. That
  user has no shell over ssh, so a stolen password or client key cannot read
  the git key or run commands in the container. It can only open the tunnel.
- The SOCKS port lets code in the container, including npm install scripts,
  open connections from the client machine. The client limits the destinations
  with `--allow`. The default of `*:443` still reaches https services on the
  client's own network, so name the registries explicitly if that matters.
- Password login is on until you set `PASSWORD_LOGIN=no`, so the first client
  can install its key. Turn it off afterwards, and only publish `SSH_PORT` on
  networks you trust (`SSH_BIND=127.0.0.1` for a client on the same machine).
- The client key has no passphrase. Anyone who copies it from the client can
  open the tunnel ports in the container, and nothing more.
- The private git key stays in the `tunnel-state` volume. `docker compose down -v`
  deletes it, and you would then add a new public key to GitHub.
- `SSH_PASSWORD` is visible to anyone who can run `docker inspect` on the host,
  and to every process started with `docker compose exec`, including npm
  install scripts. With `PASSWORD_LOGIN=no` you can delete it from `.env`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Container keeps restarting | `SSH_PASSWORD` is missing or too short. See `docker compose logs tunnel`. |
| `the machine at ... is NOT the expected container` on the client | The fingerprint does not match: wrong address, or the state volume was recreated. Get the current one from `docker compose logs tunnel`. |
| `this login only carries the tunnel and has no shell` | Expected for `ssh sshuser@host`. Use `docker compose exec -u sshuser tunnel bash` on the Docker host. |
| `Permission denied (publickey)` from the container, on the client | `PASSWORD_LOGIN=no` and this client's key is not installed. See [Client login](#client-login). |
| `could not install the key` on the client | The container image is older than the script. Run `docker compose up -d --build` on the Docker host. |
| `Connection refused` on `127.0.0.1 port 2223`, inside the container or from git on the host | The client tunnel is not running. Start `connect.sh`. |
| `No such container: git-tunnel` from git on the host | The container is not running. Run `docker compose up -d`. |
| `transport 'ext' not allowed` from git on the host | The alias exists but the permission is missing. Run `./scripts/host-setup.sh` again. |
| `Permission denied (publickey)` from GitHub | The tunnel works, but the public key is not on GitHub yet. Run `docker compose exec tunnel show-key`. |
| `remote port forwarding failed` on the client | Another tunnel already holds the port, a port differs from the container's `.env`, or the container has `PROXY_PORT=off` and the client did not pass `--no-proxy`. |
| npm fails with `502 Bad Gateway` | The client tunnel is not running, or the destination is not covered by `--allow`. `docker compose logs tunnel` names the refused host and port. |
| npm still gets `403` from the registry | The request now leaves from the client. Check that the client's own IP is accepted, and that `.npmrc` credentials are present in the container. |
| `permission denied: ./connect.sh` on the client | The copy of the script is not executable. Run `chmod +x connect.sh`, or start it with `bash connect.sh <host>`. |
| `cannot reach github.com on port 22` on the client | The client itself has no route to GitHub. The tunnel needs one. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` on the client | The state volume was recreated. Run `ssh-keygen -R '[<host>]:2222'`. |

## Commands

```bash
./scripts/setup.sh               # first start, or after changing .env
docker compose up -d --build     # build and start
docker compose logs -f tunnel    # watch sshd and see the public key
docker compose exec tunnel show-key
docker compose down              # stop, keep keys
docker compose down -v           # stop and delete keys
```
