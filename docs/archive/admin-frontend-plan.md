> Historical frontend implementation plan. Admin and analyst Angular applications are now deployed; consult the current [staff API contract](../admin-analytics/frontend-api.md) and [ECS guide](../../deployment/ecs/README.md).

# Admin frontend: what needs building

The staff API builds independently in `internal-backend/`, with admin and
analyst modules in one deployment. The Angular app still needs staff screens.
For immediate manual testing, use the separate [test console](../../internal-frontend/README.md)
on port 8086. Its plain JavaScript implementation is a working API example; these
tasks describe the final Angular interface.
Start with [the current API contract](../admin-analytics/frontend-api.md) and
[setup instructions](../admin-analytics/setup.md).

## 1. Routing and access

- [ ] Add an `admin` route with its own layout (like `ClientLayout`), guarded by `requireRole('ADMIN')`.
- [ ] Redirect to the right home after login, based on role. `auth-page.ts` currently always goes to `/client/overview`. ADMIN should go to `/admin/clients`.
- [ ] Update the `**` fallback route so admins aren't sent to a client page.
- [ ] Add admin navigation for Clients, Orders, Instruments and Audit log.

## 2. API service

- [ ] Create `src/app/api/admin/admin-api.service.ts` and `admin.ts` (types), following the pattern in `api/orders/`.
- [ ] Use the existing bearer-token interceptor. The backend gets the actor from the verified JWT; do not send `X-Admin-Id`.
- [ ] Add a type for paged responses:

  ```ts
  interface Page<T> {
    items: T[];
    page: { page: number; size: number; totalElements: number; totalPages: number };
  }
  ```

  Send `page` (0-based) and `size` (1–100, default 20) as query params.

## 3. Screens

### Client search: `GET /clients?q=&page=&size=`
- [ ] A search box (at least 3 characters, partial email match, case-insensitive) and a paged table with email, cash balance, open positions and a suspended badge.
- [ ] Each row links to the account detail.

### Account detail: `GET /accounts/{accountId}`
- [ ] Show the account summary, the positions table, and recent activity (the last 50 cash/holding changes: trades, deposits, withdrawals, dividends).
- [ ] Add a Suspend / Unsuspend button that opens a reason dialog (reason required, up to 1000 characters):
  - `POST /accounts/{id}/suspend` with `{ "reason": "..." }`
  - `POST /accounts/{id}/unsuspend` with `{ "reason": "..." }`
- [ ] After suspending or unsuspending, update the screen from the POST response, not by refetching the detail (see "Data lag" below).
- [ ] Link to "this client's orders", which is the order search filtered by `clientId`.

### Order search: `GET /orders?clientId=&symbol=&page=&size=`
- [ ] Filter by client ID and/or symbol. At least one is required, otherwise the backend returns 400.
- [ ] A paged table with symbol, side, type, quantity, limit/stop price, status badge, placed time and fill price.
- [ ] Each row links to the order lifecycle.

### Order lifecycle: `GET /orders/{orderId}/lifecycle`
- [ ] Prefer the new `/orders/{orderId}/timeline` contract with `terminal` and `provenance`. The older `/lifecycle` endpoint remains available for compatibility.
- [ ] Show the fill quantity and price on `filled`, the reason on `rejected`, and the cash and holding changes on `cash_and_holding_change`.

### Instruments
- [ ] List instruments with their `isActive` state. There's no admin list endpoint: use the existing public `GET /api/v1/instruments`.
- [ ] Add Suspend / Unsuspend with a reason dialog:
  - `POST /admin/instruments/{instrumentId}/suspend`
  - `POST /admin/instruments/{instrumentId}/unsuspend`

### Audit log: `GET /audit-log?actorId=&accountId=&action=&from=&to=&page=&size=`
- [ ] A paged table with time, admin email, action, reason, and the target (client email, symbol or order ID).
- [ ] Filters:
  - action (`view_client_account`, `view_trade`, `suspend_client`, `unsuspend_client`, `suspend_instrument`, `unsuspend_instrument`);
  - date range (`from` inclusive, `to` exclusive, ISO-8601 instants such as `2026-10-01T00:00:00Z`);
  - account.
- [ ] Add a "History" link on the account detail that opens this page filtered by `accountId`.

## 4. Shared pieces

- [ ] A reusable pager component for the `Page<T>` responses.
- [ ] A reusable reason dialog for suspend and unsuspend.
- [ ] Error handling. Errors come back as `ProblemDetail` JSON, and its `detail` field is readable text you can show directly:

  | Status | Meaning | What the UI should do |
  |---|---|---|
  | 400 | Validation error (short search, missing filter, blank reason, bad date range) | Show `detail` |
  | 403 | The caller isn't an admin | Send them away from `/admin` |
  | 404 | Account, order or instrument not found | Show "not found" |
  | 409 | Already suspended or not suspended (someone else changed it) | Show `detail` and reload the current state |

## 5. Things to know

- **Data lag.** The read endpoints come from the analytics database, which copies the trading database through Kafka. Right after a suspension, the account detail can still show the old state for a moment. The suspend/unsuspend responses come from the trading database and are always current.
- **Viewing is audited.** Each time someone opens an account detail or an order lifecycle, an audit row is written. Don't prefetch or poll those endpoints, or the audit log fills with views nobody made.
- **Enums are lowercase** (`buy`, `limit`, `filled`), the same as `/api/v1/orders`.
- **No fabricated live data.** The separate stack imports existing source records and consumes the outbox. Test fixtures are not loaded automatically.

## 6. Client-side changes caused by suspensions

- [ ] When an account is suspended, `POST /api/v1/orders` returns 400 with `detail: "Account is suspended"`. The trade dialog should show that message.
- [ ] When an instrument is suspended, orders return `"Instrument is not tradable"` and the quote endpoint refuses it. The stock search and trade dialog should handle both.
- [ ] Optional: show a "your account is suspended" banner. `AccountResponseDto` already has `suspended`.

## 7. Analyst screens

- [ ] Add an `analyst` layout guarded by `ANALYST` (and optionally `ADMIN`).
- [ ] Redirect analysts to their reporting home after login.
- [ ] Poll `/api/v1/analytics/status` for ingestion lag and the published report cutoff.
- [ ] List `/api/v1/analytics/dashboards` and embed the selected dashboard with the Superset SDK.
- [ ] Implement token renewal through the SDK's `fetchGuestToken` callback.
- [ ] Display missing/failed reports clearly; reports cover midnight to 7 PM New York time.

## 8. New audit evidence panels

- [ ] Use `/admin/trades` for the expanded ID/date/status search filters.
- [ ] Use `/admin/orders/{id}/timeline` for terminal/provenance flags.
- [ ] Show retryable pricing rejections separately from the current order status.
- [ ] Use `/admin/orders/{id}/pricing` for original quote timestamps/stale flags.
- [ ] Download `/admin/orders/{id}/export` for recorded JSON evidence.

Cancellation, amendment and stop-activation audit UI are outside this local deployment scope.

### Manual report button

The reference admin and analyst Reports pages now include **Generate daily report
now**. Implement `POST /api/v1/analytics/report-requests`, then poll
`analytics/status.latestReportRequest` while queued, disable duplicate submissions,
and offer the existing report PDF/dashboard actions when published. Coverage is
midnight New York up to the request instant. See the API contract for details.

### Auth-owned names and autocomplete

Signup sends required firstName/lastName to `/auth/register`. JWT `name` supplies
the full name for display; email is the legacy fallback. Admin client lookup and
both reference Reports pages implement debounced first/last/full-name suggestions.
Use the name-directory and published client-activity endpoints documented in the
API contract, preserve role boundaries, and distinguish duplicate names by UUID.

### Admin Orders freshness

The reference UI refreshes the current filtered Orders page every three seconds while
visible, preserving pagination and form inputs. Stop polling on logout/panel changes,
ignore responses from older sessions/searches, and retain rows on background errors.
The full-project demo loader and walkthrough provide realistic source-driven data.

### Suspension by person name

The reference Actions form now uses the admin-only `/admin/clients/suggestions`
endpoint. Type first/last name or email, select the exact account, then submit the
existing suspend/unsuspend action with a reason. Show selected name/email/status,
clear stale selections on edits, and retain UUID entry for instrument actions.

## 9. Staff security: behaviour the Angular staff UI must keep

The Angular staff console (`internal-frontend/`) does all of this: sign-in in `src/app/api.ts`
and `src/app/app.ts`, the Staff page in `src/app/pages/staff/`. Each item names the Playwright test
in `internal-frontend/tests/console.spec.js` that proves it. The servers enforce every rule; the UI
only avoids offering what they would refuse. API details: [staff sign-in and staff accounts](../admin-analytics/frontend-api.md#staff-sign-in-and-staff-accounts).

### Sign-in

- [x] **SUPER_ADMIN uses the admin workspace** like an ADMIN; every admin route accepts it. The analyst workspace stays ANALYST-only. Test: "super admin signs in to the admin workspace".
- [x] **A new staff account's first sign-in.** `POST /auth/login` can answer `{ "passwordChangeRequired": true }`, with no tokens. Show "Choose a new password" (12–72 characters, typed twice), then `POST /auth/change-temporary-password` with `{ email, password, newPassword }`, where `password` is the temporary one, kept in memory only for this step. The answer is the authenticator enrollment challenge: continue with the normal QR setup. 400 `PASSWORD_REUSED` means the new password equals the temporary one. Test: "a new staff account replaces its temporary password before authenticator setup".
- [x] **Disabled accounts.** With the correct password, login answers 403 `ACCOUNT_DISABLED`; show its `detail` ("This account is disabled. Contact an administrator."). A wrong password still gets the generic 401.
- [x] **Never trim password fields** (sign-in, reset, first sign-in): spaces are valid characters. Other fields can be trimmed. Test: "passwords keep their spaces, other fields are trimmed".
- [x] Nothing extra for the development accounts (`dev.*@example.com` with `DEV_MFA_BYPASS=true`): login returns tokens directly, the same answer optional-MFA clients get.

### Staff accounts screen (admin workspace only, e.g. `/admin/staff`)

- [x] **Create.** Email, first name, last name and a role. A SUPER_ADMIN chooses Admin or Analyst; an ADMIN gets Analyst only (read from the token's `roles`). The role chooses the route, `POST /auth/admin/staff/admins` or `/analysts`, and is **never** sent in the body (an unknown field is a 400). 409 means the email is already registered.
- [x] **Temporary password, shown once.** The 201 answer is `{ id, email, role, temporaryPassword }`. Show the password in a dialog with a copy button, never store it (no service field, no browser storage), and clear it when the dialog closes. The Clipboard API only works on a secure origin (localhost or HTTPS); elsewhere, select the text and ask the user to copy it. Test: "a super admin creates an admin and sees the temporary password only once".
- [x] **List.** `GET /auth/admin/staff` returns every staff account, super admins included: `{ id, email, firstName, lastName, role, disabledAt, passwordChangeRequired, mfaEnrolled, createdAt }`. Status, in order: disabled, must choose a password, authenticator not set up, active.
- [x] **Disable / Enable.** `POST /auth/admin/staff/{id}/disable` or `/enable` answers `{ id, email, role, disabledAt }`. Offer the button only where the server allows it: never on yourself (`id` equals the token's `sub`), never on a SUPER_ADMIN, and for an ADMIN only on ANALYSTs. Ask before disabling, because it signs the person out everywhere. Test: "an admin creates analysts only and manages only analysts".
- [x] **Rate limit.** auth-server allows 20 requests per 15 minutes per route and IP. Load the list once when the screen opens (plus a Refresh button) and update rows from each POST's answer instead of re-fetching. Show 429 as "Too many requests. Wait a few minutes, then try again." and other refusals (403, 404, 409) by their `detail`. Test: "the Staff panel shows the server refusals and a friendly rate-limit message".
- [x] **Not on the analyst workspace.** Test: "the analyst page has no Staff section".
- [x] These routes live on auth-server (`/auth/...`), not internal-backend (`/api/v1/...`). Use the same bearer token and the same 401 → refresh → retry.
