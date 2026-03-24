# IronClaw Docker-in-Docker Worker

Docker-in-Docker build of [nearai/openclaw-nearai-worker](https://github.com/nearai/openclaw-nearai-worker)'s `ironclaw-nearai-worker` image. Adds `dockerd` so IronClaw can run sandboxed workloads in nested containers, and pre-bakes the worker image into the inner Docker storage so it's available immediately without pulling.

## Requirements

The bake script uses [Sysbox](https://github.com/nestybox/sysbox) to prebake inner Docker images. Install it on the build machine before running the manual bake steps:

```bash
wget https://github.com/nestybox/sysbox/releases/download/v0.6.7/sysbox-ce_0.6.7.linux_amd64.deb
sudo dpkg -i sysbox-ce_0.6.7.linux_amd64.deb
sudo systemctl restart docker
```

## Manual bake

1. Set the image names:
   ```bash
   export UPSTREAM_IMAGE=nearaidev/ironclaw-nearai-worker:dev
   export DIND_IMAGE=ghcr.io/near-one/ironclaw-nearai-worker-dind:dev
   ```

2. Pull the upstream worker image:
   ```bash
   docker pull "$UPSTREAM_IMAGE"
   ```

3. Build the DinD wrapper image:
   ```bash
   docker build \
     --build-arg BASE_IMAGE="$UPSTREAM_IMAGE" \
     -t dind-base:local \
     .
   ```

4. Save the worker image as a tarball:
   ```bash
   docker save "$UPSTREAM_IMAGE" -o /tmp/worker.tar
   ```

5. Bake the worker tarball into the inner Docker storage:
   ```bash
   WORKER_IMAGE_ID=$(docker inspect --format='{{.Id}}' "$UPSTREAM_IMAGE")
   WORKER_REPO_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$UPSTREAM_IMAGE")
   bash scripts/bake-inner-image.sh \
     dind-base:local \
     /tmp/worker.tar \
     "$DIND_IMAGE" \
     "$WORKER_IMAGE_ID" \
     "$WORKER_REPO_DIGEST"
   ```

6. Verify the inner image is prebaked and the labels are set:
   ```bash
   docker run --runtime=sysbox-runc --rm --entrypoint bash "$DIND_IMAGE" \
     -c 'dockerd > /dev/null 2>&1 & while ! docker info > /dev/null 2>&1; do sleep 1; done; docker images'
   docker inspect --format='{{index .Config.Labels "worker.image.id"}}' "$DIND_IMAGE"
   docker inspect --format='{{index .Config.Labels "worker.repo.digest"}}' "$DIND_IMAGE"
   ```

7. Push the baked image:
   ```bash
   docker push "$DIND_IMAGE"
   ```
