# Start Asset Avengers on AWS

Use this runbook to resume the existing deployment. It does not provision new
resources, load data, change credentials or run migrations.

**Important:** starting RDS and EC2 is only part of startup. After a deliberate
cost pause, ECS services have desired count zero. EC2 can be healthy while no
application containers are running. This caused the login/signup outage diagnosed
on October 29, 2026: RDS was available, EC2 and its ECS agent were running, but all
eight services were at zero and the public auth endpoint returned HTTP 504.

Do not run scripts/start-project.sh or Docker Compose on the ECS-managed host.
The old startup helper is guarded to prevent duplicate production processes.

## 1. Select credentials and verify the account

Run these commands in Bash on a computer with AWS CLI v2 and appropriate AWS
permissions. The profile name belongs to the computer, not the project.

```bash
aws configure list-profiles
export AWS_PROFILE=YOUR_PROFILE
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=''

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || exit 1
if [ "$ACCOUNT" != '314662805698' ]; then
  echo 'Wrong AWS account; stop here.'
  exit 1
fi

export CLUSTER=asset-avengers
export INSTANCE=i-0058f31de51e5c5c8
export DATABASE=asset-avengers-db
```

The desktop used camk at the recorded check; another teammate may have a different
profile. If credentials are expired, renew them through the team's configured
sign-in method. Never paste credentials or passwords into chat or this document.

## 2. Start RDS and wait for available

```bash
STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DATABASE" \
  --query 'DBInstances[0].DBInstanceStatus' --output text) || exit 1
case "$STATUS" in
  stopped)
    aws rds start-db-instance --db-instance-identifier "$DATABASE" \
      --query 'DBInstance.DBInstanceStatus' --output text || exit 1
    ;;
  available|starting) ;;
  *) echo "RDS status is $STATUS; inspect it before proceeding."; exit 1 ;;
esac
aws rds wait db-instance-available --db-instance-identifier "$DATABASE" || exit 1
aws rds describe-db-instances --db-instance-identifier "$DATABASE" \
  --query 'DBInstances[].{Name:DBInstanceIdentifier,Status:DBInstanceStatus}'
```

Verify **available** before continuing. A waiter timeout does not authorize a
reset or replacement; inspect the status and repeat the wait if appropriate.
If RDS is still stopping, let it finish before starting it.

## 3. Start EC2 and wait for both status checks

```bash
STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE" \
  --query 'Reservations[0].Instances[0].State.Name' --output text) || exit 1
case "$STATE" in
  stopped)
    aws ec2 start-instances --instance-ids "$INSTANCE" \
      --query 'StartingInstances[].CurrentState.Name' --output text || exit 1
    ;;
  running|pending) ;;
  *) echo "EC2 state is $STATE; inspect it before proceeding."; exit 1 ;;
esac
aws ec2 wait instance-running --instance-ids "$INSTANCE" || exit 1
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE" || exit 1
aws ec2 describe-instance-status --instance-ids "$INSTANCE" \
  --query 'InstanceStatuses[].{State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}'
```

Expected: running, System ok, Instance ok. The retained Elastic IP is
54.237.94.203; normal stop/start does not require changing DNS.

## 4. Verify that EC2 is connected to ECS

```bash
CONTAINER_INSTANCE=$(aws ecs list-container-instances --cluster "$CLUSTER" \
  --query 'containerInstanceArns[0]' --output text) || exit 1
if [ "$CONTAINER_INSTANCE" = None ] || [ -z "$CONTAINER_INSTANCE" ]; then
  echo 'No ECS container instance registered; inspect the agent before continuing.'
  exit 1
fi
aws ecs describe-container-instances --cluster "$CLUSTER" \
  --container-instances "$CONTAINER_INSTANCE" \
  --query 'containerInstances[].{EC2:ec2InstanceId,Status:status,Connected:agentConnected,Running:runningTasksCount}'
```

Expected: the EC2 ID above, ACTIVE, Connected true. This deployment has one
registered application host. If it is disconnected, inspect systemctl status ecs,
systemctl status docker and journalctl -u ecs on EC2 through the team's approved
access method. Inspect errors privately; do not publish environment dumps.
Do not start the old Compose stack as a workaround.

## 5. Define a service startup-and-health check

All eight saved service counts were one. These commands restore that configuration;
they do not create duplicate extra replicas. Revisit the counts if the deployment
has intentionally changed since this runbook was written.

```bash
start_service() {
  local service="asset-avengers-$1"
  local tasks state attempt
  aws ecs update-service --cluster "$CLUSTER" --service "$service" \
    --desired-count 1 --query 'service.{Name:serviceName,Desired:desiredCount}' || return 1
  aws ecs wait services-stable --cluster "$CLUSTER" --services "$service" || return 1

  # Stable alone is insufficient: wait for the task's container health check.
  for attempt in $(seq 1 40); do
    tasks=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$service" \
      --desired-status RUNNING --query taskArns --output text) || return 1
    if [ -n "$tasks" ]; then
      state=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $tasks \
        --query 'tasks[].healthStatus' --output text) || return 1
      if [ "$state" = HEALTHY ]; then
        echo "$service is healthy"
        return 0
      fi
    fi
    sleep 15
  done
  echo "$service did not become healthy; inspect events and logs. Stop here."
  return 1
}
```

Run the next groups separately and verify each before continuing. If any command
fails, stop and investigate; do not keep launching dependent groups.

## 6. Start Kafka first

```bash
start_service kafka || exit 1
```

Kafka retains its existing host data directory. Do not initialize a new broker,
restore a backup over the active directory or run the legacy broker alongside it.

## 7. Start auth, the APIs and Superset

```bash
start_service auth || exit 1
start_service trading-api || exit 1
start_service staff-api || exit 1
start_service superset || exit 1
```

The services load the existing image and referenced Secrets Manager settings.
There is no need to rebuild images or refresh the root .env for normal startup.
Existing tasks do not automatically reread secrets after a configuration change;
that requires a separate reviewed deployment.

## 8. Start the reporting workers

```bash
start_service consumer || exit 1
start_service publisher || exit 1
start_service reporting-job || exit 1
```

Run one consumer, one publisher and one reporting scheduler in this deployment.
Ordinary publisher startup does not run historical backfill. Do not add --backfill,
load fixtures or rerun Superset initialization merely to resume services.

## 9. Verify all eight services and public routing

```bash
SERVICES=$(aws ecs list-services --cluster "$CLUSTER" \
  --query serviceArns --output text) || exit 1
aws ecs describe-services --cluster "$CLUSTER" --services $SERVICES \
  --query 'services[].{Name:serviceName,Desired:desiredCount,Running:runningCount,Pending:pendingCount}'

curl --max-time 30 -s -o /dev/null -w 'Client auth: %{http_code}\n' \
  https://www.assetavengers.top/auth/profile
curl --max-time 30 -s -o /dev/null -w 'Client API: %{http_code}\n' \
  https://www.assetavengers.top/api/v1/me/accounts
curl --max-time 30 -s -o /dev/null -w 'Staff API: %{http_code}\n' \
  https://admin.assetavengers.top/api/v1/analytics/status
curl --max-time 30 -s -o /dev/null -w 'Analyst API: %{http_code}\n' \
  https://analyst.assetavengers.top/api/v1/analytics/status
curl --max-time 30 -s -o /dev/null -w 'Superset health: %{http_code}\n' \
  https://analytics.assetavengers.top/health
```

Expected: eight services, each desired 1 / running 1 / pending 0; protected
endpoints return **401 without credentials**, while Superset health returns 200.
A 401 here is expected, not a login failure. A 502/504 is not an expected auth response.

Then use an existing authorized account to verify actual login and the intended
role's screen. Signup creates data and may send email; perform it only with an
approved test identity. Do not put a password into shell commands, Git or screenshots.
Readiness checks alone do not prove signup email delivery or authenticated workflows.

Staff projections can take time to catch up. Charts also require published report
facts and matching filters; a missing chart row is not a reason to reset data.

## 10. If startup fails

| Symptom | First checks |
| --- | --- |
| UI loads, login/signup times out | Auth desired/running count, task health, public /auth/profile response |
| ECS task stays pending | Connected agent, available memory/CPU, port conflicts, service events |
| Task stops/restarts | Stop reason and the affected service's CloudWatch logs |
| Database errors | RDS available, network reachability, TLS, connected DB/user and object permissions |
| Invalid credentials | Existing account and password policy; do not assume empty auth tables contain users |
| MFA required | Account policy/enrollment; do not broadly enable a dev bypass |
| Staff data is stale | Kafka, publisher/consumer health, heartbeat and pending outbox |
| Superset charts empty | Reader permissions, report publication and filters |

Read-only diagnostic commands:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services asset-avengers-auth \
  --query 'services[].events[:5].[createdAt,message]'
aws ecs list-tasks --cluster "$CLUSTER" --service-name asset-avengers-auth \
  --desired-status STOPPED --query taskArns
aws logs describe-log-streams --log-group-name /ecs/asset-avengers \
  --log-stream-name-prefix service/auth/ --order-by LogStreamName \
  --query 'logStreams[].logStreamName'
```

Select the relevant stream and inspect it privately with CloudWatch or
aws logs get-log-events. Logs can contain account details; avoid publishing raw
output. Task definitions contain secret references, not permission to expose values.

## What does not need to be started manually

S3, ECR, CloudFront, DNS and Secrets Manager do not have an EC2-style start button.
Leave existing resources and DNS records in place. Nginx, Docker and the ECS agent
are host services; verify their startup if origin or agent checks fail. EC2 startup
alone cannot change ECS desired counts from zero to one.

A future cost pause must save desired counts and stop services in dependency order
before stopping EC2/RDS. RDS can restart automatically after seven days, and retained
storage/public IPv4 resources still cost money. Use the
[ECS operations guide](../deployment/ecs/README.md) for pause and rollback details.

Related: [deployment explanation](asset-avengers-cloud-deployment-story.md) and
[general CLI migration handbook](local-to-aws-migration-guide.md).
