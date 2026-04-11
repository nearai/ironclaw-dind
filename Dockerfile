# Adds Docker-in-Docker on top of nearaidev/ironclaw so IronClaw can run
# sandboxed workloads in nested containers (requires Sysbox or --privileged).

ARG IRONCLAW_IMAGE=nearaidev/ironclaw:latest
FROM docker:27-dind AS docker-bin

FROM ${IRONCLAW_IMAGE}

USER root

# Interactive shell quality: UTF-8 locale, bash-completion. Skel matches
# openclaw-nearai-worker/ironclaw-worker (.profile → .bashrc); entrypoint copies
# into IRONCLAW_HOME when the user is created or home has no dotfiles.
COPY shell/ironclaw.bashrc /etc/skel/.bashrc
COPY shell/ironclaw.profile /etc/skel/.profile

# Single apt pass: one index fetch, one layer (shell + DinD deps + SSH + sudo + locales).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        bash-completion \
        curl \
        iptables \
        less \
        locales \
        openssh-server \
        sudo \
    && sed -i '/C\.UTF-8 UTF-8/s/^# *//' /etc/locale.gen \
    && locale-gen \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Copy Docker CLI and daemon from official image — ~60MB vs ~266MB from apt
COPY --from=docker-bin /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-bin /usr/local/bin/dockerd /usr/local/bin/dockerd
COPY --from=docker-bin /usr/local/bin/containerd /usr/local/bin/containerd
COPY --from=docker-bin /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v2
COPY --from=docker-bin /usr/local/bin/runc /usr/local/bin/runc
COPY --from=docker-bin /usr/local/bin/docker-proxy /usr/local/bin/docker-proxy

COPY dind-entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod 755 /usr/local/bin/dind-entrypoint.sh

# Source digest label for scheduled rebuild detection
ARG IRONCLAW_SOURCE_DIGEST=""
LABEL ironclaw.source.digest="${IRONCLAW_SOURCE_DIGEST}"

ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]
