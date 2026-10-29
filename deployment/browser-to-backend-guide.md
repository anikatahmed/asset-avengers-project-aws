# Browser-to-backend migration walkthrough

This is a general guide for walking through the migration one step at a time.
Saving this guide does not apply AWS or backend configuration changes.
Superset configuration is deferred.

## Verified starting point (2026-10-28)

- Frontend builds are in S3 and served through CloudFront.
- Client: `www.assetavengers.top`, distribution `E1ZBORDTDBION2`.
- Staff: `admin.assetavengers.top` and `analyst.assetavengers.top`, shared
  distribution `E2FSFUK5002OFP`.
- The client distribution already forwards `/auth/*` to EC2 port 3000 and
  `/api/*` to port 8080. Unauthenticated checks returned 401.
- The staff distribution currently has only an S3 origin. Staff API/auth checks
  returned S3 XML errors, confirming that forwarding is missing.
- EC2: `i-0058f31de51e5c5c8`, Elastic IP `54.237.94.203`, in `us-east-1`.
- The team confirms the application containers are running and RDS is reachable.
  Running containers have not been inspected independently over SSH.
- Repository Compose files publish auth on 3000, trading on 8080, and staff on
  `127.0.0.1:8085`.
- Existing `frontend/nginx.conf` and `internal-frontend/nginx.conf` belonged to
  frontend containers, which the current AWS Compose deployment no longer starts.
- Frontends use relative `/auth/...` and `/api/...` URLs. No frontend rebuild is
  expected for this routing migration.

## Target request flow

Browser -> CloudFront -> HTTPS Nginx ingress on EC2 -> backend containers -> RDS.
CloudFront continues serving UI files from S3. API/auth responses are not cached.

## 1. Inspect EC2 and verify local services

Connect using the team's working EC2 access method. Before installing Nginx,
identify the OS, check whether Nginx is already installed, inspect containers and
listeners, and check whether ports 80 or 443 are occupied. Preserve any existing
ingress configuration.

Run on EC2:

```bash
docker ps
sudo ss -lntp
curl -i http://127.0.0.1:3000/health/ready
curl -i http://127.0.0.1:8080/actuator/health/readiness
curl -i http://127.0.0.1:8085/api/v1/analytics/status
```

Readiness should return 200; the protected staff endpoint should reject a request
without a token. Resolve local failures before changing CloudFront.

## 2. Install and configure a standalone host Nginx

Use installation commands appropriate to the verified EC2 OS. Host Nginx can
reach the existing published container ports through loopback; Docker service
names and Docker's `127.0.0.11` resolver from the old frontend configurations do
not apply to host Nginx.

Forward these paths without removing their prefixes:

| Browser path | Host-side upstream |
| --- | --- |
| `/auth/` | `http://127.0.0.1:3000` |
| `/api/v1/admin/` | `http://127.0.0.1:8085` |
| `/api/v1/analytics/` | `http://127.0.0.1:8085` |
| Other `/api/` requests | `http://127.0.0.1:8080` |

Preserve authorization, cookies, query strings, request bodies, and HTTP methods.
Do not serve Angular fallback HTML for failed API/auth requests. Keep the staff
port bound to loopback; do not open 8085 publicly.

Configure trusted forwarded headers and client-IP handling. Auth currently trusts
one proxy hop in `auth-server/src/app.setup.ts`; adding Nginx behind CloudFront
must not make all users appear to have an edge server's IP for rate limiting.
Avoid blindly trusting arbitrary forwarded headers from public clients.

Validate with `sudo nginx -t` and test routing locally before enabling/reloading.

## 3. Configure HTTPS for the origin

Proposed origin hostname: `origin.assetavengers.top`.

1. Add an A record in Spaceship pointing that hostname to `54.237.94.203`.
2. Provision and install a trusted TLS certificate for that hostname on Nginx.
3. Configure the HTTPS listener on 443 and verify hostname/certificate agreement.
4. Test the ingress before switching CloudFront behaviors to it.

The existing CloudFront viewer certificates do not automatically install a
certificate on EC2. The EC2 security group currently permits port 443; verify
current rules and host firewall when implementing. Review restrictions to the
intended origin callers without disrupting existing access.

## 4. Add staff CloudFront routing in AWS Console

Open distribution `E2FSFUK5002OFP`.

Origins -> Create origin:

| Setting | Value |
| --- | --- |
| Origin domain | `origin.assetavengers.top` |
| Protocol | HTTPS only |
| HTTPS port | 443 |
| Origin path | Empty |
| Name | `ec2-ingress` |

Behaviors -> Create behavior: create `/auth/*` and `/api/v1/*`, with these
settings on each:

| Setting | Value |
| --- | --- |
| Origin | `ec2-ingress` |
| Viewer protocol | Redirect HTTP to HTTPS |
| Allowed HTTP methods | All seven |
| Cache policy | `CachingDisabled` |
| Origin request policy | `AllViewerExceptHostHeader` |
| Function associations | None |

The origin request policy forwards viewer values except Host, allowing the
origin hostname to match the Nginx certificate and virtual host. Leave the default
S3 behavior and its staff UI routing function in place. Do not add a global
error-to-index response that masks backend errors.

## 5. Verify browser-to-container forwarding

Wait for CloudFront to show Deployed. Then check:

```bash
curl -i https://admin.assetavengers.top/auth/profile
curl -i https://analyst.assetavengers.top/api/v1/analytics/status
```

Expect backend authentication rejection without credentials, rather than S3 XML,
HTML, or a gateway error. Then verify real staff sign-in and authorized data loading
using browser developer tools. Check Nginx/backend logs for diagnosis without
printing tokens or passwords.

These tests prove different things: a readiness response verifies service health;
an unauthenticated response verifies routing; authorized browser requests verify
the complete login and data flow.

## 6. Migrate client routing only after staff succeeds

The client currently reaches its backend directly through CloudFront, so leave
that working configuration in place initially. Once shared ingress is verified,
add the HTTPS ingress origin to `E1ZBORDTDBION2` and move `/auth/*` and `/api/*`
to it with caching disabled and the matching request policy. Retest client login
and API calls. Preserve backend role checks on every route.

## References checked

- [AWS origin settings](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesOrigin.html)
- [AWS behavior settings](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesCacheBehavior.html)
- [AWS managed origin request policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html)
- [AWS managed cache policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html)
