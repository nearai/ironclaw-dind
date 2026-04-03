# Adds Docker-in-Docker on top of nearaidev/ironclaw so IronClaw can run
# sandboxed workloads in nested containers (requires Sysbox or --privileged).

ARG IRONCLAW_IMAGE=nearaidev/ironclaw:latest
FROM ${IRONCLAW_IMAGE}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends docker.io iptables \
    && rm -rf /var/lib/apt/lists/*

COPY dind-entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod 755 /usr/local/bin/dind-entrypoint.sh

# Source digest label for scheduled rebuild detection
ARG IRONCLAW_SOURCE_DIGEST=""
LABEL ironclaw.source.digest="${IRONCLAW_SOURCE_DIGEST}"

ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]
