# IronClaw Docker-in-Docker Worker

Docker-in-Docker build of [nearai/openclaw-nearai-worker](https://github.com/nearai/openclaw-nearai-worker)'s worker image. Adds `dockerd` so IronClaw can run sandboxed workloads in nested containers, and pre-bakes the sandbox image into the inner Docker storage so it's available immediately without pulling.

## Architecture

The DinD image contains two layers:

- **Outer image** — the `openclaw-nearai-worker` image plus `dockerd`. Runs the full worker entrypoint (SSH, secrets, IronClaw orchestrator).
- **Inner image** — the sandbox image built from [nearai/ironclaw](https://github.com/nearai/ironclaw)'s `Dockerfile.worker`. Has `ENTRYPOINT ["ironclaw"]` and runs in worker/claude-bridge mode when the orchestrator spawns a job container. Pre-baked into the outer image's inner Docker storage as `ironclaw-worker:latest`.

These are **different images** from **different repos**. The outer image manages the full worker lifecycle; the inner image is a minimal sandbox that receives commands from the orchestrator.

## Requirements

The bake script uses [Sysbox](https://github.com/nestybox/sysbox) to prebake inner Docker images. Install it on the build machine before running the manual bake steps:

```bash
wget https://github.com/nestybox/sysbox/releases/download/v0.6.7/sysbox-ce_0.6.7.linux_amd64.deb
sudo dpkg -i sysbox-ce_0.6.7.linux_amd64.deb
sudo systemctl restart docker
```

## Manual bake

1. Set the upstream image and output tag:
   ```bash
   export UPSTREAM_IMAGE=nearaidev/ironclaw-nearai-worker:dev
   export DIND_IMAGE=ghcr.io/near-one/ironclaw-dind:dev
   ```

2. Pull the upstream worker image and detect the ironclaw version:
   ```bash
   docker pull "$UPSTREAM_IMAGE"
   export IRONCLAW_VERSION=v$(docker run --rm --entrypoint ironclaw "$UPSTREAM_IMAGE" --version | awk '{print $2}')
   echo "Detected IronClaw $IRONCLAW_VERSION"
   ```

3. Build the DinD wrapper image:
   ```bash
   docker build \
     --build-arg BASE_IMAGE="$UPSTREAM_IMAGE" \
     -t dind-base:local \
     .
   ```

4. Build the sandbox image (inner) from the ironclaw repo:
   ```bash
   git clone --branch "$IRONCLAW_VERSION" --depth 1 \
     https://github.com/nearai/ironclaw.git /tmp/ironclaw-build
   docker build \
     -f /tmp/ironclaw-build/Dockerfile.worker \
     -t ironclaw-sandbox:local \
     /tmp/ironclaw-build
   rm -rf /tmp/ironclaw-build
   ```

5. Save the sandbox image as a tarball:
   ```bash
   docker save ironclaw-sandbox:local -o /tmp/sandbox.tar
   ```

6. Bake the sandbox tarball into the inner Docker storage:
   ```bash
   SANDBOX_IMAGE_ID=$(docker inspect --format='{{.Id}}' ironclaw-sandbox:local)
   bash scripts/bake-inner-image.sh \
     dind-base:local \
     /tmp/sandbox.tar \
     "$DIND_IMAGE" \
     "$SANDBOX_IMAGE_ID" \
     "$IRONCLAW_VERSION"
   ```

7. Verify the inner image is prebaked and the labels are set:
   ```bash
   docker run --runtime=sysbox-runc --rm --entrypoint bash "$DIND_IMAGE" \
     -c 'dockerd > /dev/null 2>&1 & while ! docker info > /dev/null 2>&1; do sleep 1; done; docker images'
   docker inspect --format='{{index .Config.Labels "sandbox.image.id"}}' "$DIND_IMAGE"
   docker inspect --format='{{index .Config.Labels "ironclaw.version"}}' "$DIND_IMAGE"
   ```

8. Push the baked image:
   ```bash
   docker push "$DIND_IMAGE"
   ```
