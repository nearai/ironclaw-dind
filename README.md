# IronClaw Docker-in-Docker

Thin wrapper on [nearaidev/ironclaw](https://hub.docker.com/r/nearaidev/ironclaw) that adds `dockerd` so IronClaw can run sandboxed workloads in nested containers. Requires Sysbox or `--privileged`.

## What it adds

- Docker CLI/daemon binaries + `iptables`
- A DinD entrypoint that starts `dockerd`, verifies the baked `ironclaw-worker:latest` image is available in the inner Docker store, then execs `ironclaw`

Everything else (the ironclaw binary, runtime, user) comes from the base image.

## Build

The build helper pulls the sandbox worker image at build time, saves it to an
archive, loads it into a temporary DinD container's inner Docker store, and
commits the final image. Runtime startup then uses the local inner-Docker image
instead of pulling from the network.

```bash
bash scripts/build-dind-image.sh \
  ironclaw-dind \
  nearaidev/ironclaw:latest \
  local
```

By default the baked sandbox source is derived from the IronClaw image tag
(`nearaidev/ironclaw:<tag>` -> `nearaidev/ironclaw-worker:<tag>`) and the
inner-Docker alias is `ironclaw-worker:latest`. Override them with:

```bash
SANDBOX_IMAGE_SOURCE=nearaidev/ironclaw-worker:<tag> \
SANDBOX_IMAGE_ALIAS=ironclaw-worker:latest \
bash scripts/build-dind-image.sh ironclaw-dind nearaidev/ironclaw:<tag> <source-digest>
```

The bake step starts a temporary DinD container with `--runtime=sysbox-runc` by
default. For local Docker Desktop checks without Sysbox, use
`DIND_BAKE_RUN_ARGS=--privileged`.

## Run

```bash
docker run --runtime=sysbox-runc ironclaw-dind
```

The entrypoint fails fast if the sandbox image is missing and does not let
IronClaw auto-pull it by default. To restore the old runtime-pull fallback for
development, set `SANDBOX_PULL_IF_MISSING=true`.

Do not mount `/var/lib/docker` as a persistent volume for normal deployments.
That directory contains the baked inner-Docker image store; persisting it across
image upgrades can mask the worker image bundled in the new `ironclaw-dind`
image.
