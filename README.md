# Asset Avengers Trading Platform

## Running on AWS

Angular applications are hosted in S3/CloudFront and PostgreSQL databases in RDS.
Compose runs the APIs, auth, Kafka, reporting workers and Superset.
Follow [AWS runtime setup](deployment/aws-runtime.md) to prepare databases, fill
`.env`, and configure frontend/API routing before starting:

```bash
bash scripts/start-project.sh
```

Stop application stacks with `bash scripts/stop-project.sh`; persistent data is preserved.

## Documentation

- [Complete project guide](docs/project-guide.md): architecture, login, databases, orders, live updates and setup.
- [Code map](docs/code-map.md): where each feature starts and which files it calls.
- [Design decisions](docs/design-decisions.md): why the components and data flows work this way.
- [Database reference](DB/README.md): table ownership, relationships, triggers, views and seed files.
- [Persistence and API usage](docs/persistence-and-api-usage.md): saved accounts and quote credit controls.
- [Order processing](docs/order-processing.md): validation, reservations and execution.
- [Admin and analyst backend](docs/admin-analytics/README.md): separate staff API, pipeline, dashboards and Compose setup.

## Repository Structure

- `backend/` - Client trading API and business logic
- [`internal-backend/`](internal-backend/README.md) - Shared staff Spring Boot API: admin and analyst features
- [`internal-frontend/`](internal-frontend/README.md) - Shared staff test UI (port 8086)
- [`admin-analytics/`](admin-analytics/README.md) - Reporting infrastructure: Python pipeline and Superset
- [`deployment/admin-analytics/`](deployment/admin-analytics/README.md) - Deployment configuration that starts the staff services together
- [`deployment/`](deployment/README.md) - Guide to the client and staff Compose files
- `frontend/` - Angular application
- `auth-server/` - NestJS login, sessions and token service
- `DB/` - Database schemas and catalogue/auth fixtures
- `scripts/` - SQL seed synchronization and database verification
- `docker-compose.yml` - AWS trading API/auth runtime using RDS
- `README.md` - project overview and team workflow

## Local setup and catalogue changes

Copy `.env.example` to `.env` and configure RDS endpoints, service credentials,
a shared JWT secret, frontend origins and the pricing API key as described in the
[AWS runtime guide](deployment/aws-runtime.md). CI uses separate disposable local stacks.

The instrument catalogue source is `DB/instruments.seed.sql`. After editing it, run:

```bash
python3 scripts/generate-instrument-seed.py
python3 scripts/generate-instrument-seed.py --check
```

Apply schema/catalogue migrations to RDS explicitly before deploying. Normal
startup does not initialize databases or load fixtures. `setup-test-db.sh` is for
local database testing only.

Before pushing, include the new guide, SQL seed, helper scripts and new Java/Angular
files along with modified files. Keep `.env`, generated build output and database
storage out of the commit.

## Start both client and staff applications

After configuring the single root `.env` from root `.env.example` and following the
[first-time staff setup](docs/admin-analytics/setup.md), run:

```bash
bash scripts/start-project.sh
```

Client: `http://localhost:8084`. Admin login: `http://localhost:8086/admin.html`.
Analyst login: `http://localhost:8086/analyst.html`. There is no shared login landing
page; each page requires its matching role. The helper preserves saved data.

## Team
- Aidan Jones
- Cameron Kelly
- Anika Ahmed
- Andrei Zubek
- Christopher Saez

## Branching Strategy
### Git Flow
- We decided to use git flow to keep individual development on feature branches, which will need to be kept up to date as changes are continuously merged into a development branch. When a sprint is completed, we will make a pull request to the main/prod branch, review all changes as a group, and then merge.

## Notes

- Order validation, separate execution, setup and tests: [Order processing](docs/order-processing.md).
- The backend was reorganized from the generated Spring Initializr folder into `backend/` to keep the repository ready for the Angular frontend.
- IDE files and build output should stay untracked through the root `.gitignore`.

## Optional full-project demonstration

After `bash scripts/start-project.sh`, run `bash scripts/load-demo-data.sh` to load
named demo clients with funding, banks, holdings, watchlists, orders, audit evidence
and published reports through the normal pipeline. This is opt-in and preserves
subsequent account changes on reruns. See [demo walkthrough](docs/demo-walkthrough.md)
for logins, expected balances and a presentation sequence. Admin Orders updates its
current filtered page automatically every three seconds while visible.


## Presentation guide and current workspace names

See [presentation guide](docs/presentation-guide.md) for Ultron (admin), J.A.R.V.I.S. (analyst), development logins, spread/return examples, PDF interpretation and the expanded 99-client / 2,526-fill demo. Staff development images use `:local`. Existing data is preserved; run the demo loader to add the extension.
