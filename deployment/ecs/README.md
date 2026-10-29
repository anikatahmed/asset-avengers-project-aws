# Asset Avengers ECS deployment

Account `314662805698`, region `us-east-1`, cluster `asset-avengers`.
Compute: existing EC2 `i-0058f31de51e5c5c8` (`m6a.large`). No new EC2,
Fargate capacity, NAT gateway or load balancer was provisioned.
All new taggable resources carry `project=asset-avengers`.

## Repository layout

- `tasks/`: the eight production task-definition inputs.
- `images/`: current image manifests and source checksums.
- `state/`: cluster/service references, execution-role details and rollback/backup records.
- `verification/`: smoke tests, security findings and the completed read-only auth probe.
- `history/`: older immutable image manifests.
- `kafka/`: patched broker Dockerfile.
- `superset-upgrade-review/`: upgrade candidate and critical-finding assessment.

These are repository records and deployment inputs. Moving them into these folders
has not changed the registered AWS task definitions or running services.

## Services

| ECS service suffix | Host port / role | ECR repository suffix |
| --- | --- | --- |
| auth | 3000 | auth |
| trading-api | 8080 | trading-api |
| staff-api | 8085 | staff-api |
| superset | 8088 | superset |
| kafka | 9092 | kafka |
| publisher | outbox delivery | reporting-pipeline |
| consumer | reporting projection | reporting-pipeline |
| reporting-job | report scheduling | reporting-pipeline |

Names have the `asset-avengers-` prefix; repositories have `asset-avengers/`.
Task definitions pin image digests. Repositories have immutable tags and basic
scan-on-push. Full dependency scans were also performed locally with Trivy
0.76.1, since ECR basic scans do not establish application-dependency safety.
Image snapshots record source checksums and uncommitted working-tree status;
older snapshots are retained in `history/`. No Git commit or push was performed.

Services use Docker bridge networking on the existing host. Public domains,
CloudFront origins, host Nginx routing, S3 frontends and RDS databases remain in
place. Internal ECS-to-ECS HTTP/Kafka endpoints use host private IP
`10.200.1.118` and the existing ports. Security groups were not opened for the
staff API, Superset or Kafka ports. Services are constrained to this EC2 instance,
including Kafka's local persistent storage. This deployment does not provide
multi-host availability or automatic host replacement.

## Data and secrets

No database reset, fixture load, account creation or metadata migration ran.
Superset remains **6.0.0**, with compatible security patches and explicit
screenshot/report safeguards; 6.1 remains a separately reviewed candidate.
The PostgreSQL databases, Kafka data volume, existing dashboard IDs and chart
configuration were retained. The publisher starts without `--backfill`.

Kafka remains 4.1.2 with vendor Alpine OS updates. Its task binds only the
existing data directory recorded in `images/kafka-image.json`. A protected, verified
archive was made while the broker was stopped; location is in
`state/kafka-backup.state.json`. Never run two brokers against that directory or
restore the archive over a running broker. There is one publisher, consumer and
scheduler; legacy processes were stopped before ECS processes started.

ECS injects individual JSON keys from `matrix/production/credentials` using the
execution role; task JSON contains references, not secret values. Auth verifies
RDS TLS using AWS's public regional CA bundle. Critical passwords, JWT/MFA/SSO
and Superset encryption settings were compared in memory and remained equal to
the retained legacy containers. No credentials were changed. CloudWatch logs
are under `/ecs/asset-avengers` with 14-day retention.

## Security results and limits

- Auth and reporting pipeline: no Trivy findings at the recorded scan time.
- Trading and staff APIs: Tomcat 11.0.27, Jackson 2.21.7/3.1.7; zero critical or
  high findings; 44 medium and 4 low findings each. Maven tests passed (276 total,
  9 skipped for trading; 83 total, 6 skipped for staff).
- Superset 6.0: seven critical findings remain, with the path/prerequisite
  assessment in `superset-upgrade-review/critical-assessment.md`. This is not a
  clean scan or a package-level remediation. Optional server-side thumbnails,
  screenshot reports and Playwright processing are explicitly disabled. Existing
  embedded dashboards and PostgreSQL reporting jobs remain enabled.
- Kafka OS patch removed all six critical findings from its original image.
  Eighteen high Java dependency findings remain. Do not replace broker jars
  individually to bypass vendor compatibility; review a supported Kafka upgrade
  separately. The broker port has no public security-group ingress.
- No scanner findings were suppressed. Point-in-time findings do not establish
  absence of future vulnerabilities. Verification summaries are in the
  `verification/` directory.

## Operations and rollback

The ECS agent (1.108.1) is enabled through systemd. Docker's existing systemd
cgroup driver was retained. Task-level cgroup resource limits are disabled for
compatibility; per-container memory limits/reservations remain configured.
The agent reserves 3072 MiB for the host and unmanaged overhead.

Legacy containers are retained **stopped**, with Docker restart disabled. Their
names and former restart policy appear in `state/*-service.state.json`. The old
`start-project.sh` is guarded on this host by
`/etc/ecs/asset-avengers.managed`, preventing duplicate Compose startup. The
remote original script is retained as `scripts/start-project.sh.before-ecs`.
Use ECS for routine service operations. Refreshing root `.env` does not update
ECS tasks; secret changes require a deliberate ECS deployment.

Services use desired count one, minimum healthy percent zero, maximum percent
100, health checks and deployment circuit-breaker rollback. Fixed ports and a
single host mean replacements can briefly interrupt a service. To deploy a new
image, test it, publish a new immutable tag, register a digest-pinned task
revision, and update the corresponding ECS service. Do not run initialization
or bootstrap jobs as part of the Superset web service.

For a manual rollback, first scale the affected ECS service to zero and verify
its task has stopped and released the port. Only then restore the retained
legacy container's `unless-stopped` restart policy and start it. Kafka rollback
also requires pausing workers and verifying only one broker owns the data path.
Restore the old internal Docker-DNS dependencies together when reverting the
whole stack; avoid a mixture of legacy upstream names and ECS host endpoints.
Never start a legacy publisher or scheduler alongside its ECS replacement.

When restarting the environment, make RDS available first, then start EC2 and
verify the agent and eight ECS services. A host reboot interrupts all services;
DNS and EIP do not need to change for a normal stop/start of this instance.
