# Docker deployment configuration

This folder contains Docker deployment configuration, rather than application code.
The admin and analyst Java code lives in [internal-backend](../internal-backend/README.md).

## Which Compose file should I use?

| File | Starts | Browser address |
| --- | --- | --- |
| [../docker-compose.yml](../docker-compose.yml) | Client Angular UI, trading Spring API, shared auth service, trading and auth databases | Client app: `http://localhost:8084` |
| [admin-analytics/admin-analyst-stack.compose.yml](admin-analytics/admin-analyst-stack.compose.yml) | Shared admin/analyst API and test UI, reporting database, Kafka, reporting jobs and Superset | Admin: `http://localhost:8086/admin.html`; analyst: `http://localhost:8086/analyst.html`; Superset: `http://localhost:8088` |
| [admin-analytics/admin-analyst-tests.override.yml](admin-analytics/admin-analyst-tests.override.yml) | An override for isolated staff verification, used with the staff Compose file | Test runner controls access; not the normal startup file |

A **Compose file** describes which containers to run, how to build them, their
configuration, ports, networks, startup dependencies and persistent storage.
The descriptive filenames identify the normal staff stack and its isolated test
override. Because these are custom filenames, pass the correct path with `-f`.
It does not contain a second implementation of your Spring application.

Start the root client stack first. The staff stack reuses its authentication and
trading services through the shared Docker network. The staff stack runs as a
separate Compose project named `asset-avengers-internal`, with its own reporting
and Kafka volumes. Start both stacks to use the full project.

From the repository root, after configuring the single repository-root `.env` from root `.env.example`:

```bash
# Client, trading and authentication.
docker compose up -d --build

# Admin and analyst system; all settings come from root .env.
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml up -d --build
```

See the [staff setup guide](../docs/admin-analytics/setup.md) for initial configuration
and existing-database migration steps. The obsolete root `new-compose.yml` is not
required. [DB/docker-compose-proddb.yml](../DB/docker-compose-proddb.yml) only
starts an alternative database; it does not start either full application stack.

## EC2 build runs out of disk space (`ENOSPC`)

Check disk space and inodes on the filesystem storing Docker data:

```bash
docker info --format '{{.DockerRootDir}}'
df -h
df -i
docker system df
```

For example, if Docker reports `/var/lib/docker`, check `df -h /var/lib/docker`
and `df -i /var/lib/docker`. Reclaim unused build cache with:

```bash
docker builder prune
```

This prompts before removing unused build cache; subsequent builds may take longer.
It does not remove database volumes. Avoid `docker system prune --volumes` and
`docker compose down --volumes` when preserving saved data.
See [Docker build-cache cleanup](https://docs.docker.com/build/cache/garbage-collection/).

Retry with `bash scripts/start-project.sh --client` for the client/auth/trading
stack, or `bash scripts/start-project.sh` for both stacks. The helper builds
services sequentially, including only one build for each shared staff image,
then starts containers using those images. Direct `docker compose up --build`
can still build services concurrently. npm caches are cleaned in dependency
installation layers, and auth installs dependencies once, pruning development
dependencies after compilation for its runtime image.

These changes reduce build storage pressure but cannot make a full disk usable.
If cache cleanup is insufficient, increase the EBS volume backing Docker, then
extend its partition/filesystem as described in the
[AWS EBS filesystem guide](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html).
Use that guide's commands for the actual device and filesystem reported by
`lsblk -f` and `df -hT`; device names vary between instances.
