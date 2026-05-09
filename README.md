# IronClaw Docker-in-Docker

Thin wrapper on [nearaidev/ironclaw](https://hub.docker.com/r/nearaidev/ironclaw) that adds `dockerd` so IronClaw can run sandboxed workloads in nested containers. Sysbox is the preferred runtime; `--privileged` can be used as a less-isolated fallback when Sysbox is unavailable or unsupported.

## What it adds

- Docker CLI/daemon binaries + `iptables`
- A DinD entrypoint that starts `dockerd`, verifies the baked worker image is available in the inner Docker store, then execs `ironclaw`

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

By default the baked sandbox image is derived from the IronClaw image tag
(`nearaidev/ironclaw:<tag>` -> `nearaidev/ironclaw-worker:<tag>`). Override it
with:

```bash
SANDBOX_IMAGE=nearaidev/ironclaw-worker:<tag> \
bash scripts/build-dind-image.sh ironclaw-dind nearaidev/ironclaw:<tag> <source-digest>
```

The bake step starts a temporary DinD container with `--runtime=sysbox-runc` by
default. On hosts where Sysbox is unavailable or unsupported, set
`DIND_BAKE_RUN_ARGS=--privileged` as a less-isolated compatibility fallback.

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
