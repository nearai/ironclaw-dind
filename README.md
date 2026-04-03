# IronClaw Docker-in-Docker

Thin wrapper on [nearaidev/ironclaw](https://hub.docker.com/r/nearaidev/ironclaw) that adds `dockerd` so IronClaw can run sandboxed workloads in nested containers. Requires Sysbox or `--privileged`.

## What it adds

- `docker.io` + `iptables` packages
- A DinD entrypoint that starts `dockerd`, pre-pulls `nearaidev/ironclaw-worker` in the background, then execs `ironclaw`

Everything else (the ironclaw binary, runtime, user) comes from the base image.

## Build

```bash
docker build --build-arg IRONCLAW_IMAGE=nearaidev/ironclaw:latest -t ironclaw-dind .
```

## Run

```bash
docker run --runtime=sysbox-runc ironclaw-dind
```
