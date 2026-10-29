# Prompt: Asset Avengers AWS system diagram

Copy the prompt below into your diagram assistant.

```text
Create an AWS system architecture diagram for our Asset Avengers application using Mermaid. Explain the connections briefly below it.

Inspect the repository’s deployment records before drawing:
- deployment/ecs/README.md
- deployment/ecs/tasks/
- deployment/aws-runtime.md
- deployment/superset-aws.md
- docs/asset-avengers-cloud-deployment-story.md

Use the newest records when older guides conflict. Do not expose secret values or change AWS resources.

Our architecture:
- AWS Region: us-east-1.
- DNS provider: Spaceship.
- Angular frontends are hosted in private S3 buckets through CloudFront with Origin Access Control.
- Client domain: www.assetavengers.top.
- Admin and analyst domains share a staff CloudFront distribution and frontend build.
- Analytics domain: analytics.assetavengers.top, pointing directly to EC2 Nginx over HTTPS.
- ECS manages eight services on ONE existing EC2 instance:
  1. Auth — port 3000
  2. Trading API — port 8080
  3. Staff API — port 8085
  4. Superset — port 8088
  5. Kafka — port 9092
  6. Outbox publisher
  7. Reporting consumer
  8. Reporting scheduler
- ECR stores six images; the three reporting services share one pipeline image.
- ECS uses EC2 capacity, not Fargate.
- There is no ALB, NAT gateway, Kubernetes cluster or automatic host replacement.
- EC2 has a stable Elastic IP and host Nginx with Certbot certificates.
- Staff CloudFront forwards /auth/* and /api/v1/* over HTTPS to origin.assetavengers.top; Nginx routes them to auth and the staff API.
- The recorded client CloudFront routes /auth/* and /api/* directly to EC2 over HTTP. Show this separately from the staff HTTPS origin; do not silently redraw it as upgraded.
- ONE private RDS PostgreSQL instance contains FOUR logical databases:
  auth, Endgame_Trading, admin_analytics, superset_metadata.
- Auth uses auth; Trading uses Endgame_Trading; staff/reporting uses admin_analytics.
- Superset stores configuration in superset_metadata and reads reporting data from admin_analytics.
- Reporting flow: trading transaction → transactional outbox → publisher → Kafka → consumer → reporting projections → report scheduler → published report data → Superset charts.
- Kafka persists data on the EC2 host.
- Secrets Manager injects referenced configuration into ECS tasks.
- CloudWatch collects container logs.
- IAM roles authorize AWS access; security groups restrict network access.

Produce:
1. A readable infrastructure diagram with AWS Region, VPC, public application subnet, private database subnet group, and the single EC2 host clearly bounded. Keep S3, CloudFront and other regional/global managed services outside the VPC boundary.
2. A separate reporting data-flow diagram to avoid crowding the first.
3. A short explanation of login, trading and analytics request paths.
4. A brief cost rationale: we reused EC2 capacity, hosted static frontends in S3, and avoided adding Fargate, an ALB or NAT gateway. Mention the single-host availability trade-off without claiming this is always the cheapest architecture.

Use labeled arrows, distinguish deployment/configuration connections from user traffic, and make clear that eight ECS services share one EC2 host and four databases share one RDS instance. Do not invent missing components or claim that historical verification proves current availability.
```
