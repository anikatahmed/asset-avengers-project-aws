# Frontend API handoff

For immediate testing, use the [standalone staff console](../../internal-frontend/README.md)
on port 8086. It proxies the same API paths; this contract also applies to the final Angular UI.

Use `/api/v1/admin` and `/api/v1/analytics` through the existing Nginx origin.
During Angular development, proxy these paths to `http://localhost:8085` and the
remaining client APIs to the existing trading backend. Send the existing bearer
access token; **do not send `X-Admin-Id`**.

Admin routes require `ADMIN` or `SUPER_ADMIN`. Analytics routes allow `ANALYST`, `ADMIN` and `SUPER_ADMIN`.
The internal service verifies signature, expiry, issuer, the `endgame-staff` audience (only staff tokens
carry it) and MFA proof (`amr` contains `pwd` and `mfa`).
A 401 means authentication is missing/invalid; a 403 means the role is insufficient.

## Required MFA and password reset contract

Ultron and J.A.R.V.I.S. use the same `/auth` service. For staff, `/auth/login` returns a
challenge, or `passwordChangeRequired` for a new account (see [staff sign-in](#staff-sign-in-and-staff-accounts)).
`purpose: enroll` includes `enrollmentRequired`, `secret` and
`qrDataUrl`; require QR setup, then POST `challengeToken` and `code` to
`/auth/mfa/enable`. Show the returned recovery codes and require acknowledging
that they were saved before opening the workspace. Enrolled users receive
`purpose: login`; submit the code to `/auth/mfa/verify` to obtain normal tokens.
Challenge tokens are temporary in-memory state, never API bearer tokens.

The pages also support proof-based authenticator replacement and **Forgot password?**.
`/auth/forgot-password` accepts email and returns a generic message plus `requestToken`.
`/auth/verify-reset-code` accepts `requestToken` and `code` and returns a five-minute
`resetToken`. Only then show the password form. `/auth/reset-password` accepts that
verified `resetToken` and `newPassword`; it rejects the current password with
`PASSWORD_REUSED`. Cooldown returns 429 `RESET_REQUEST_LIMIT` and must preserve the
original challenge instead of clearing it. Success
returns no application tokens: return to password-plus-authenticator login. Email
verification at signup is intentionally disabled during testing. Neither a password
reset nor an email code removes MFA. See [MFA endpoints](../mfa.md) and
[email reset examples](../email-service.md). Spring requires the signed JWT's
`amr` claim to include `pwd` and `mfa`; the role checks below still apply.

## Staff sign-in and staff accounts

**New staff accounts.** A super admin creates admins; an admin or super admin creates analysts.
The new account signs in with a one-time temporary password, and `/auth/login` answers
`{"passwordChangeRequired": true}`: no tokens, no challenge. POST `email`, the temporary
`password` and `newPassword` (12–72 characters, different from the temporary one) to
`/auth/change-temporary-password`; its answer is the `purpose: enroll` challenge above.
Until then, `/auth/mfa/setup` and `/auth/mfa/replace/start` answer 403 `PASSWORD_CHANGE_REQUIRED`.

**Disabled accounts.** With the correct password, `/auth/login` answers 403 `ACCOUNT_DISABLED`
(`detail`: "This account is disabled. Contact an administrator."). A wrong password still gets
the generic 401, and refresh fails with 401.

**Staff-account routes.** These live on auth-server and take the same bearer token (with MFA proof).
They're limited to 20 requests per 15 minutes per route and IP, with 429 beyond that.

| Route | Who | Body | Answer |
|---|---|---|---|
| `GET /auth/admin/staff` | ADMIN, SUPER_ADMIN | none | `[{id, email, firstName, lastName, role, disabledAt, passwordChangeRequired, mfaEnrolled, createdAt}]` |
| `POST /auth/admin/staff/admins` | SUPER_ADMIN | `{email, firstName, lastName}` | 201 `{id, email, role, temporaryPassword}`, `Cache-Control: no-store`; 409 if the email exists |
| `POST /auth/admin/staff/analysts` | ADMIN, SUPER_ADMIN | `{email, firstName, lastName}` | Same as above |
| `POST /auth/admin/staff/{id}/disable` | ADMIN, SUPER_ADMIN | none | `{id, email, role, disabledAt}`; ends the account's sessions |
| `POST /auth/admin/staff/{id}/enable` | ADMIN, SUPER_ADMIN | none | Same, with `disabledAt: null` |

- **The body never carries a role.** An unknown field is a 400.
- **Disable and enable refuse (403):**
  - yourself
  - any SUPER_ADMIN
  - for an ADMIN, anyone but an ANALYST
- **A non-staff id is a 404.**
- **`temporaryPassword` is shown once and never stored.**

`docs/archive/admin-frontend-plan.md` section 9 describes the screen.

**Development accounts.** With `DEV_MFA_BYPASS=true` in a local `.env`, `dev.superadmin@`, `dev.admin@`
and `dev.analyst@example.com` get tokens straight from `/auth/login`, as optional-MFA clients do
([development switch](../mfa.md#development-switch)). No UI change is needed.

## Admin endpoints

Existing routes are retained after moving to the separate service:

| Method and path | Purpose |
|---|---|
| `GET /admin/clients?q=&page=&size=` | Email search, at least three characters |
| `GET /admin/accounts/{id}` | Copied account, positions and recent cash movements |
| `GET /admin/orders?clientId=&symbol=&page=&size=` | Existing search contract; at least one filter |
| `GET /admin/orders/{id}/lifecycle` | Existing lifecycle contract |
| `GET /admin/audit-log` | Staff views and authoritative suspension actions |
| `POST /admin/accounts/{id}/suspend` or `/unsuspend` | Forward an authorized command to trading |
| `POST /admin/instruments/{id}/suspend` or `/unsuspend` | Forward an authorized command to trading |

Suspension body: `{ "reason": "Review requested" }`. Responses contain the current
trading state; copied read endpoints may briefly lag. The command and its staff
audit record commit together in the trading database.

New audit routes:

| Method and path | Parameters/result |
|---|---|
| `GET /admin/trades` | Optional `clientId`, `orderId`, `fillId`, `instrumentId`, `symbol`, `status`, `from`, `to`, `page`, `size` |
| `GET /admin/orders/{id}/timeline` | Order summary plus events with stable IDs, terminal flag and provenance |
| `GET /admin/orders/{id}/pricing` | Original quotes and observation/decision details |
| `GET /admin/orders/{id}/export` | Download JSON containing the timeline, original quotes and linked cash movements |

`from` is inclusive and `to` exclusive, based on order placement time. Supply ISO
instants, e.g. `2026-10-01T04:00:00Z`. Page numbers start at 0; size is 1–100,
default 20. The search result shape is:

```json
{
  "items": [],
  "page": { "page": 0, "size": 20, "totalElements": 0, "totalPages": 0 }
}
```

The timeline response includes an `order` object using the existing camelCase
order DTO and an `events` array, for example:

```json
{
  "eventId": "40000000-0000-0000-0000-000000000001",
  "eventType": "rejected",
  "eventAt": "2026-10-01T13:00:01Z",
  "quantity": null,
  "price": null,
  "rejectionReason": "Quote does not contain a valid execution price",
  "terminal": false,
  "provenance": "recorded"
}
```

Show `terminal=false` rejections as **execution attempt rejected; order may retry**.
Use `order.status` for the current operational state. `provenance=snapshot` means
the event is an imported known state, with incomplete historical evidence.

Pricing entries contain `evidenceId`, `orderId`, `phase` (`submission` or
`execution`), `decision`, `reason`, `observedAt`, and a `quote` object. Display the
provider `asOf` independently from `observedAt`; a recently fetched closing quote
can have an old provider timestamp and `stale=true`. Preserve unknown values as
unknown. Failed submission requests that never became orders are outside this local deployment.

Opening an account/timeline/pricing view is audited. Poll the search/status APIs for
freshness; do not repeatedly poll audit-detail endpoints as background activity.

## Analytics endpoints

`GET /analytics/status` returns:

- `reportingTimezone`: `America/New_York`.
- `cutoffLocalTime`: today's configured time, initially `19:00`.
- `reportSchedule`: current and next-day schedule information.
- `coverage`: same day, midnight inclusive through the configured cutoff exclusive.
- `pipeline`: source heartbeat, receipt time, latest event ID and approximate lag.
- `latestBatch`: newest attempted batch (`running`, `published`, or `failed`).
- `latestPublishedBatch`: the batch actually visible to dashboards.

Before ingestion/reporting starts, the corresponding objects are `null`. Render
an empty/loading state instead of fabricated zeros or an assumed current report.
A failed newer batch can coexist with an older successfully published report.

`GET /analytics/dashboards` lists configured `dashboardKey`, `title`, `embeddedId`.
The prepared keys are `business-overview`, `instrument-activity`, `client-activity`.

`POST /analytics/dashboards/{key}/guest-token` returns:

```json
{
  "guestToken": "short-lived-superset-token",
  "dashboardId": "configured-embedded-dashboard-uuid",
  "supersetUrl": "http://localhost:8088"
}
```

Use `@superset-ui/embedded-sdk`. Its `fetchGuestToken` callback should call this
endpoint again when the SDK renews the short-lived token. The existing application
JWT goes only to our API; the returned guest token goes to the embedding SDK.
No Superset username/password belongs in Angular. Configure the exact Angular
origin in `SUPERSET_EMBED_ORIGINS` and preserve a referrer policy that allows
Superset to check the permitted embedding origin.

```typescript
// Example handoff, to integrate into the Angular teammate's component/service.
const fetchEmbedding = () => firstValueFrom(
  http.post<{ guestToken: string; dashboardId: string; supersetUrl: string }>(
    '/api/v1/analytics/dashboards/business-overview/guest-token', {}
  )
);
const initial = await fetchEmbedding();
const embedded = await embedDashboard({
  id: initial.dashboardId,
  supersetDomain: initial.supersetUrl,
  mountPoint: dashboardElement,
  fetchGuestToken: async () => (await fetchEmbedding()).guestToken,
  dashboardUiConfig: { hideTitle: true, filters: { expanded: true } }
});
// On Angular component destruction: embedded.unmount().
```

The prepared dashboards support dates, instruments, security classes, sides and
clients. Segments/portfolio valuation are deferred. Filters change presentation;
they do not grant access to data.

## Errors

Explicit business errors use `ProblemDetail.detail`. Authentication failures from
the security filter may have an empty body, so provide a generic fallback.

| Status | Handling |
|---|---|
| 400 | Show invalid filter/reason detail |
| 401 | Use the existing single refresh flow, then return to login if necessary |
| 403 | Show insufficient staff permissions |
| 404 | Unknown order/dashboard/resource |
| 409 | Suspension state already changed; refresh current state |
| 502 | Trading service or Superset is unavailable; allow retry |
| 503 | Reporting database unavailable or dashboard initialization incomplete |

The internal Swagger page is available at port 8085 for the live generated schema.

## Shared daily report schedule

`GET /analytics/report-schedule` reads the current setting.
`PUT /analytics/report-schedule` accepts `{ "localTime": "17:30" }`. Both require
ADMIN or ANALYST; CLIENT and anonymous callers cannot change the setting.
Times must be HH:mm from 00:01 through 23:59, always America/New_York. Example:

```json
{
  "timezone": "America/New_York",
  "currentLocalTime": "19:00",
  "nextLocalTime": "17:30",
  "effectiveFrom": "2026-10-16"
}
```

Changes start tomorrow in New York, apply to all staff, and control both the run
time and cutoff. Today's already-effective schedule and published batches remain
unchanged. New versions retain the verified actor; no browser-supplied actor is
accepted. The worker notices changes on its next 30-second check. These endpoints
do not start ETL synchronously or change continuous Kafka ingestion.

## Role-specific login pages and PDF files

The staff UI uses `/admin.html` and `/analyst.html`, with no shared root login page.
Authentication still uses the same auth service; UI role checks complement backend
authorization. Tokens remain in memory, and each page rejects the wrong role.

| Route | Roles | PDF contents |
| --- | --- | --- |
| `GET /analytics/reports/{YYYY-MM-DD}/pdf` | ADMIN, ANALYST | Published daily business summary, instrument activity and original batch/cutoff metadata |
| `GET /admin/orders/{UUID}/pdf` | ADMIN | Saved lifecycle, pricing evidence and cash movements, matching JSON export |
| `GET /admin/audit-log/pdf?from=YYYY-MM-DD&to=YYYY-MM-DD` | ADMIN | Staff activity within inclusive UTC dates |

Responses have `application/pdf`, an attachment filename and `Cache-Control: no-store`.
Use the authenticated `request(..., { download: true })` helper to receive a Blob.
An unpublished report is 404. Invalid ranges are 400. Audit exports allow at most
32 inclusive days and 1,000 rows; report exports allow 1,000 instrument groups.
Oversized exports are 413 and never silently truncated. Analysts do not gain access
to admin audit logs through the export routes. PDFs use [Apache PDFBox](https://pdfbox.apache.org/3.0/getting-started.html).

## Manual daily report publication

`POST /api/v1/analytics/report-requests` (ADMIN or ANALYST, empty JSON body) returns
HTTP 202 and `{requestId, requestedBy, cutoffAt, status, batchId, completedAt, error}`.
The shared queue reuses queued work and successful requests from the last minute.
Read `GET /api/v1/analytics/status` → `latestReportRequest` to track `queued`,
`published` or `failed`; poll every three seconds only while queued. On success,
refresh report metadata and offer the existing PDF download and dashboard reopening.
The worker uses midnight New York through the request timestamp, even before the
scheduled cutoff; the normal daily schedule continues independently. Generation
may wait for synchronization. Never describe the button as an immediate synchronous
PDF download.

## Client name autocomplete

Both staff roles: `GET /api/v1/analytics/clients/suggestions?q=ca` returns up to ten
`{clientId,firstName,lastName,fullName}` matches from copied client names. Empty
queries return an empty array; queries are limited to 100 characters. Debounce
250 ms, ignore responses for older queries, and render text safely. Select by UUID,
not by name. `GET /api/v1/analytics/clients/{uuid}/activity` returns the most recent
31 published `{reportDate,tradeCount,tradedNotional}` rows. No account balances or
emails are exposed to analysts. Admin `GET /api/v1/admin/clients?q=...` now also
matches full names, retaining its three-character minimum and pagination.

## Admin suspension account picker

`GET /api/v1/admin/clients/suggestions?q=ca` (ADMIN/SUPER_ADMIN only) returns up to ten
`{clientId,accountId,fullName,email,suspended}` results matching first/last/full name
or email. Blank queries return `[]`; nonblank queries are limited to 100 characters.
Debounce 250 ms, ignore stale responses, and distinguish duplicate names/accounts by
email and account ID. Selecting a result fills the account UUID internally. Clear
selection whenever the query/resource changes; do not allow typed names to resolve
to an arbitrary account. Existing suspend/unsuspend POST routes still require the
selected account UUID and `{reason}`. Never expose this endpoint to the analyst UI.


Client names in orders and dashboards: Ultron displays `clientName` alongside order IDs in search results and order details; the same name is included in order PDF/JSON evidence. Superset uses `analytics.named_published_trades`, joining the current copied client directory to published facts. Its client activity table groups by both name and UUID, and charts/filters use a name-plus-ID label. For example, Cameron Kelly appears beside his client ID rather than as a UUID alone. Missing names show “Unknown client”; the UUID remains available. Names are current directory labels, not a claim about the person's name at the historical trade time. Enrichment does not change the publication cutoff or financial totals. Rerunning dashboard initialization upgrades prepared client charts and filters while preserving dashboard layouts.

### Superset authoring SSO

`GET /api/v1/analytics/workspace` returns public `url` (SQL Lab) and `ssoUrl`
(`/endgame/sso`) fields to authenticated staff. The public hostname follows the
configured Superset URL and port. On an analyst click, rotate the session and POST
the current refresh token to `/auth/superset/ticket`; form POST the returned one-use
`ticket` to `ssoUrl` in a new tab. Never put any credential in a query string. The
backchannel `/auth/superset/exchange` and `/session` APIs require the server-only
`X-Endgame-SSO-Secret`; browsers must not call them. Superset's protected session
remains bound to the active MFA-authenticated ANALYST session. See
[SSO details and examples](../jarvis-superset-workspace.md).

### Current portfolio-size filters

`GET /api/v1/analytics/clients/portfolios?q=Cam&portfolioClass=B` returns at most 100 clients matching the name and current observed USD class. A is above $100,000, B is $10,000–$100,000 inclusive, C is below $10,000. Use `unclassified` for missing/non-USD prices; omit class for all clients. Response fields include `clientId`, `clientName`, `cashBalance`, `holdingsValue`, `portfolioValue`, `currency`, `portfolioClass`, `portfolioSizeBand`, `valuationStatus`, `unpricedPositions`, `oldestQuoteAt`, `accountUpdatedAt`. Render null values as unavailable, never zero. `valuationStatus` is `observed`, `stale`, or `unpriced`. Values include cash and market-value holdings across all accounts; they are current copied observations, not historical published snapshots. See [database guide](database-guide.md) for examples and caveats.

### Investment account identity

Order, account and admin suggestion DTOs include `accountName` and `accountType` alongside `accountId`; admin dispute rows expose the same labels. `GET /api/v1/analytics/clients/{id}/accounts` lists that client's copied investment accounts without emails/bank details. Client activity now separates date/account groups, returning `accountId`, `accountName`, `accountType`, `tradeCount`, `tradedNotional` (up to 100 groups). See [full examples and history semantics](investment-account-visibility.md). Client disputes POST an owned `accountId` and, optionally, an order belonging to that account.
