# IronClaw Docker-in-Docker worker image.
#
# Gets the ironclaw binary from nearaidev/ironclaw, adds SSH, Docker daemon,
# dev tools, and the worker entrypoint so it can run as a DinD agent with
# sandboxed nested containers (requires Sysbox or --privileged).

ARG IRONCLAW_IMAGE=nearaidev/ironclaw:latest
FROM ${IRONCLAW_IMAGE} AS ironclaw-bin

FROM debian:bookworm-slim

# Install SSH, Docker, and dev tools in one layer
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server \
      ca-certificates \
      libssl3 \
      curl \
      git \
      build-essential \
      python3 \
      jq \
      procps \
      vim \
      less \
      nano \
      sudo \
      login \
      docker.io \
      iptables \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy ironclaw binary from the upstream image
COPY --from=ironclaw-bin /usr/local/bin/ironclaw /usr/local/bin/ironclaw

# Create non-root user (UID 1001, matching compose-api worker pattern)
RUN useradd -m -u 1001 -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent \
    && usermod -aG docker agent

# Install Rust toolchain for agent user (available via SSH)
USER agent
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.92.0
USER root

# Configure SSH, directories, and agent environment
RUN mkdir -p /home/agent/.ssh /home/agent/ssh /home/agent/.ironclaw/channels /home/agent/workspace && \
    chmod 700 /home/agent/.ssh && \
    printf '%s\n' '[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' > /home/agent/.profile && \
    echo 'source "$HOME/.cargo/env"' >> /home/agent/.bashrc && \
    chown -R agent:agent /home/agent

# IronClaw's sandbox spawner hardcodes /workspace as the mount target inside
# subagent containers. Create a symlink so both paths resolve to the same place.
RUN ln -s /home/agent/workspace /workspace

# Copy entrypoint
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

COPY dind-entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod 755 /usr/local/bin/dind-entrypoint.sh

# Source digest label for scheduled rebuild detection
ARG IRONCLAW_SOURCE_DIGEST=""
LABEL ironclaw.source.digest="${IRONCLAW_SOURCE_DIGEST}"

WORKDIR /home/agent

# Expose gateway and SSH ports
EXPOSE 18789 2222

ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]
