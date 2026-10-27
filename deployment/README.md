# Deployment

See [AWS runtime setup](aws-runtime.md) for the current S3/CloudFront and RDS deployment.

| Compose file | Purpose |
| --- | --- |
| `../docker-compose.yml` | Trading API and auth server using RDS |
| `admin-analytics/admin-analyst-stack.compose.yml` | Staff API, Kafka, reporting workers and Superset using RDS |
| `ci/ci.compose.yml` | Disposable client/auth CI services, including local PostgreSQL and Angular |
| `admin-analytics/admin-analyst-ci.compose.yml` | Disposable staff CI base with local reporting PostgreSQL and Angular |

Start applications after preparing RDS and configuring root `.env`:

```bash
bash scripts/start-project.sh
```

Angular is built separately and deployed to S3/CloudFront. No Angular builds or
PostgreSQL containers run in the two deployment stacks.

If Docker reports `ENOSPC`, check `df -h`, `df -i` and `docker system df`.
`docker builder prune` prompts before reclaiming unused build cache without removing
database volumes. If space remains insufficient, expand the EBS volume and its
filesystem. Java/Superset builds and Kafka storage still need EC2 disk space.
