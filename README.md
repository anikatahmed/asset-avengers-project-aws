# Asset Avengers Trading Platform

## Running application

The backend services run on **ECS on the existing EC2 instance**. Images are in
ECR, databases are in private RDS, and Angular frontends are hosted in
S3/CloudFront.

- Client: https://www.assetavengers.top
- Admin: https://admin.assetavengers.top
- Analyst: https://analyst.assetavengers.top
- Superset: https://analytics.assetavengers.top

To restart the environment, make RDS available first, start EC2, then verify
all eight ECS services are healthy. The ECS agent is enabled on the host.
**Do not run `scripts/start-project.sh` or Docker Compose on the ECS-managed host.**

For a new team moving a local application to AWS, use the
[CLI migration handbook](docs/local-to-aws-migration-guide.md), including service
definitions, cost choices, database alternatives and Mermaid diagrams.

After a deliberate cost pause, ECS service counts may be zero. Starting EC2
alone does not restore them: follow the recorded
[pause/resume procedure](deployment/ecs/README.md#recorded-cost-pause).

Start with the [ECS deployment and operations guide](deployment/ecs/README.md).
It covers image versions, task definitions, storage, secrets, verification,
security follow-ups and rollback. No startup step resets databases or loads demo data.

## Repository map

| Folder | Purpose |
| --- | --- |
| `backend/` | Client trading API |
| `auth-server/` | Login, MFA, sessions and tokens |
| `frontend/` | Client Angular application |
| `internal-backend/` | Admin and analyst API |
| `internal-frontend/` | Admin and analyst Angular application |
| `admin-analytics/` | Reporting pipeline and Superset image source |
| `DB/` | Database schemas, catalogue, migrations, demo fixtures and database tests |
| `deployment/ecs/` | Current ECS tasks, image manifests, state and verification |
| `deployment/rds/` | Database provisioning/recovery tools, not normal startup |
| `deployment/ci/`, `deployment/admin-analytics/` | CI/testing and retained Compose configurations |
| `scripts/` | Development, CI and maintenance helpers |
| `docs/` | Feature guides, API contracts and design decisions |
| `deployment/archive/`, `docs/archive/` | Historical plans and completed migration material |
| `UML/` | Supporting design diagrams |

## Development and data

Use the [testing guide](docs/testing-guide.md) and [CI guide](docs/jenkins-ci.md)
for isolated development/test stacks. The Compose files are retained for those
workflows and rollback reference; they no longer control the live ECS services.

Database schemas remain necessary even though RDS is already configured.
See [database documentation](DB/README.md) and [RDS maintenance](deployment/rds/README.md).
Demo fixtures are retained for isolated environments. The existing
`scripts/load-demo-data.sh` is disabled for shared RDS; loading demo data there
requires a reviewed workflow that protects existing accounts and balances.
See the [demo walkthrough](docs/demo-walkthrough.md) for historical demo content.

The catalogue source is `DB/instruments.seed.sql`. After editing it:

```bash
python3 scripts/generate-instrument-seed.py
python3 scripts/generate-instrument-seed.py --check
```

Keep `.env`, credentials, dependencies and generated build output out of Git.
`.env.example` documents configuration names; live ECS tasks receive secret
references from Secrets Manager.

## Documentation

- [Start Asset Avengers on AWS](docs/start-asset-avengers-on-aws.md)
- [How we moved Asset Avengers to AWS: architecture, problems and fixes](docs/asset-avengers-cloud-deployment-story.md)
- [AWS operations](deployment/aws-runtime.md)
- [Project guide](docs/project-guide.md) and [code map](docs/code-map.md)
- [Design decisions](docs/design-decisions.md)
- [Persistence and API usage](docs/persistence-and-api-usage.md)
- [Order processing](docs/order-processing.md)
- [Admin and analyst architecture](docs/admin-analytics/README.md)
- [Repository cleanup notes](deployment/archive/README.md)

## Team

Aidan Jones, Cameron Kelly, Anika Ahmed, Andrei Zubek, Christopher Saez.

## Branching

The team uses feature branches merged into development, then reviews changes
before merging into the main/production branch.
