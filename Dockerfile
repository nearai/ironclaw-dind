# Adds Docker-in-Docker on top of nearaidev/ironclaw so IronClaw can run
# sandboxed workloads in nested containers (requires Sysbox or --privileged).

ARG IRONCLAW_IMAGE=nearaidev/ironclaw:latest
FROM docker:28-dind AS docker-bin

FROM ${IRONCLAW_IMAGE}

USER root

# Copy Docker CLI and daemon from official image — ~60MB vs ~266MB from apt
COPY --from=docker-bin /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-bin /usr/local/bin/dockerd /usr/local/bin/dockerd
COPY --from=docker-bin /usr/local/bin/containerd /usr/local/bin/containerd
COPY --from=docker-bin /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v2
COPY --from=docker-bin /usr/local/bin/runc /usr/local/bin/runc
COPY --from=docker-bin /usr/local/bin/docker-proxy /usr/local/bin/docker-proxy

RUN apt-get update \
    && apt-get install -y --no-install-recommends iptables openssh-server \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*

COPY dind-entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod 755 /usr/local/bin/dind-entrypoint.sh

# Source digest label for scheduled rebuild detection
ARG IRONCLAW_SOURCE_DIGEST=""
LABEL ironclaw.source.digest="${IRONCLAW_SOURCE_DIGEST}"

ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]
