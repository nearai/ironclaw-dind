# Adds Docker-in-Docker on top of the ironclaw worker so IronClaw can run
# sandboxed workloads in nested containers (requires Sysbox or --privileged).

ARG BASE_IMAGE=nearaidev/ironclaw-nearai-worker:latest
FROM ${BASE_IMAGE}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends docker.io iptables \
    && usermod -aG docker agent \
    && rm -rf /var/lib/apt/lists/*

# The base entrypoint hardcodes SANDBOX_ENABLED=false; enable it for DinD.
RUN sed -i 's/export SANDBOX_ENABLED=false/export SANDBOX_ENABLED=${SANDBOX_ENABLED:-true}/' /app/entrypoint.sh

# The base worker mounts workspace at /home/agent/workspace, but IronClaw's
# sandbox spawner (container.rs) hardcodes /workspace as the mount target inside
# subagent containers. Create a symlink so both paths resolve to the same place.
RUN ln -s /home/agent/workspace /workspace

COPY dind-entrypoint.sh /usr/local/bin/dind-entrypoint.sh
RUN chmod 755 /usr/local/bin/dind-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]
