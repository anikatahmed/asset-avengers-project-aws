# Staff CloudFront deployment

AWS account: `314662805698`. Resources created on 2026-10-28.

## Hosting

- Distribution: `E2FSFUK5002OFP`
- Default domain: `dnu1l3h4ac7cm.cloudfront.net`
- Staff frontend bucket: `asset-avengers-admin-analyst-bucket`
- Origin access control: `E381I50SGV69E3` (`asset-avengers-staff-s3`)
- Viewer-request function: `asset-avengers-staff-rewrite`
- Intended custom domains: `admin.assetavengers.top`, `analyst.assetavengers.top`
- ACM certificate in `us-east-1`: `6e7104e6-ac2b-457c-bef5-8765ed53ca3a`

The distribution redirects HTTP to HTTPS. Its default behavior uses managed
CachingDisabled while deployment is being configured, and the managed
SecurityHeadersPolicy. A dedicated function rewrites `/`, `/admin`, `/analyst`,
and their extensionless child routes to `/index.html`; assets and API/auth paths
are not rewritten. There is no global error-to-index fallback.
Requests for `/` or `/index.html` on the admin hostname redirect to `/admin`;
the analyst hostname redirects to `/analyst`. Redirects preserve query strings
and use `Cache-Control: no-store`. These hostnames select the entry page;
backend role authorization still controls access.

S3 Block Public Access remains enabled. The bucket policy grants `s3:GetObject`
only to the CloudFront service principal for this distribution and account.
The existing client distribution `E1ZBORDTDBION2` is unchanged by this deployment.

## Access logs

Standard logging v2 uses delivery `Wle96uw7fdYpamHQ`:

- Source: `asset-avengers-staff-cf`
- Destination: `asset-avengers-staff-s3`
- Bucket: `asset-avengers-staff-access-logs-314662805698`

The log bucket blocks public access, uses SSE-S3 encryption, and expires logs
after 30 days. Selected JSON fields cover date/time, method, path, status, edge
result, timing, and TLS. Cookies and query strings are excluded. Storage and log
delivery destination usage are billed under normal AWS pricing.

## Pending work

The certificate is issued, with both domains successfully DNS-validated. These
CNAME records are in Spaceship; retain them for renewals (TTL: Default):

| Host | Target |
| --- | --- |
| `_a3376331861abcca4866df000100337c.admin` | `_a586178dcf3a848db636a28485419650.wzccmgtwzk.acm-validations.aws` |
| `_522c566902101114b7873947451bd50a.analyst` | `_9ed930317f408a34d0c19290952ea035.wzccmgtwzk.acm-validations.aws` |

The certificate and both custom domain aliases are attached to the staff
distribution, with minimum viewer TLS policy `TLSv1.2_2025`. CloudFront reports
`Deployed`. The `admin` and `analyst` CNAME records both point to
`dnu1l3h4ac7cm.cloudfront.net` in Spaceship. Verified both domains with normal
HTTPS requests: each returned HTTP 200 with valid TLS after redirecting to
`/admin` and `/analyst`, respectively. This verifies static hosting and entry
routing; login/API and analytics integration remain unfinished as noted below.
The earlier `staff.assetavengers.top` certificate request is unused; it has not
been attached to the distribution.

Login and API behaviors are not yet configured. EC2 SSH access timed out, and
the instance is not registered with Systems Manager; no Instance Connect
endpoint was present. The repository binds the staff API on EC2 loopback port
8085, so CloudFront cannot directly reach it. Confirm the live services and set
up reachable ingress before adding API behaviors. Do not open port 8085 to the
public internet or treat the static UI alone as a working staff application.

Required same-origin routes:

| Path | Service |
| --- | --- |
| `/auth/*` | Existing auth service |
| `/api/v1/*` | Staff API on port 8085 via ingress |

API/auth behaviors must disable caching and preserve authorization headers,
cookies, query strings, and required HTTP methods. Use HTTPS for custom origin
connections or an appropriately restricted private origin. Keep API errors out
of Angular route fallback. Verify unauthenticated requests return authorization
errors rather than HTML, then test staff sign-in with an authorized account.
Analytics dashboards additionally require a reachable HTTPS Superset endpoint
and the staff origin in its configured embedding allowlist.

Final entry URLs will be `https://admin.assetavengers.top` and
`https://analyst.assetavengers.top` once these remaining steps are complete.
