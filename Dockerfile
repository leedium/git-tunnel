# git-tunnel: an sshd container that reaches a git server (GitHub by default)
# through a reverse SSH tunnel opened by a client machine.
#
# Nothing secret is baked into this image. The login password, the sshd host
# keys and the GitHub key are all created at container start by
# docker/entrypoint.sh, from .env and the /state volume.

# Node.js major version (or exact version) installed in the container. It runs
# the HTTP-to-SOCKS proxy shim and gives you npm.
ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm-slim AS node

FROM ubuntu:24.04

# UID of the login user. Match it to your host user on Linux so files in the
# bind-mounted workspace have the right owner. Irrelevant on Docker for Mac.
ARG SSH_UID=1000

# Add any extra tools you want inside the container to this list.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssh-server \
        openssh-client \
        ca-certificates \
        curl \
        git \
        sudo && \
    rm -rf /var/lib/apt/lists/* && \
    # The package generates host keys at install time. Remove them so no two
    # installs of this image ever share a host key.
    rm -f /etc/ssh/ssh_host_*

# ubuntu:24.04 ships a default "ubuntu" user on UID 1000. Replace it.
RUN (userdel -r ubuntu 2>/dev/null || true) && \
    useradd -m -u "${SSH_UID}" -s /bin/bash sshuser && \
    mkdir -p /home/sshuser/work /state && \
    chown sshuser:sshuser /home/sshuser/work

# Node.js and npm, copied from the official image.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    node --version && npm --version

# GitHub's published host keys, so the real server is verified through the
# tunnel without a trust prompt.
COPY docker/github_known_hosts /etc/ssh/ssh_known_hosts
COPY docker/sshd_tunnel.conf /usr/local/share/git-tunnel/sshd_tunnel.conf
COPY docker/http-to-socks.js /usr/local/share/git-tunnel/http-to-socks.js
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/show-key /usr/local/bin/show-key
RUN chmod 644 /etc/ssh/ssh_known_hosts && \
    chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/show-key

VOLUME /state
EXPOSE 2222

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
