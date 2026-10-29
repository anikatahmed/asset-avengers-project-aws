# Code map: where to read and change each feature

Paths in this document are relative to the repository root. Start with
[the project guide](project-guide.md) for the complete diagram and
[design decisions](design-decisions.md) for the reasons behind the boundaries.
Source comments explain local responsibilities; this map connects them across
languages, services and databases.

## Common Java patterns

`*Controller` maps HTTP requests and obtains identity; `*Service` performs the
business operation; `*Repository` reads/writes storage. JPA entity annotations map
Java fields to the canonical SQL columns. Request DTOs describe input and validation;
response DTOs expose selected fields. `*Mapper` translates those shapes without
making a business decision. Enums must match the SQL/JSON values. Exceptions and
controller advice turn validation/storage errors into HTTP responses.

These patterns explain the small DTO/entity/enum files throughout both backends.
Package-level `package-info.java` comments describe the domain and its collaborators.
The staff backend uses local DTOs and JDBC, so its build does not depend on client
JPA entities. SQL is defined in `DB/`, not generated as production schema by DTOs.

## Client Angular app (`frontend/`)

| Files / directory | Used for and connected to |
|---|---|
| `src/main.ts`, `src/index.html`, `app/app.ts`, `app/app.html` | Bootstrap and render the Angular root/router outlet |
| `app/app.config.ts` | Registers HTTP interceptor, router and session restoration before guarded navigation |
| `app/app.routes.ts` | Login/signup and CLIENT-guarded layout with overview, portfolio, orders, banking and stock search |
| `auth/auth.service.ts` | Login/register/logout and shared refresh; memory access token, per-tab persisted refresh token |
| `auth/auth.interceptor.ts` | Adds bearer tokens to `/api` calls; retries once after refresh on 401 |
| `auth/auth.guard.ts` | Navigation based on decoded roles; actual authorization is enforced by Spring |
| `auth/idle.service.ts`, `idle-dialog.ts` | User-activity timeout and warning; polling does not count as activity |
| `auth/api-error.ts` | Converts API failures into user-facing messages |
| `auth/pages/auth-page/`, `auth/components/portfolio-preview/` | Shared login/signup form and illustrative landing-page presentation |
| `client/layout/client-layout.*` | Navigation shell; starts portfolio/quote polling and unsubscribes when the layout is destroyed |
| `client/state/portfolio.store.ts` | Signals for server snapshots, selected quotes, holdings, watchlist and computed values; session/version checks reject stale responses |
| `api/bank-accounts/` | Typed banking requests and account snapshot; calls `/api/v1/bank-accounts/...` |
| `api/instruments/` | Catalogue/ticker lookup and shared company-name matching; matching the saved list costs no provider request |
| `api/quotes/` | Display quote DTO/HTTP adapter; no provider secret in the browser |
| `api/orders/` | Order contracts and create/list/cancel requests; acceptance is not execution |
| `client/pages/overview-page/`, `portfolio-page/` | Compose portfolio summary, holdings, watchlist and allocation views from the shared store |
| `client/pages/orders-page/` | Shows order history; cancellation updates status from the backend response |
| `client/pages/bank-accounts-page/` | Manage funding sources and submit simulated deposits/withdrawals; refresh saved portfolio after success |
| `client/pages/stock-search-page/` | Select catalogue matches or verify an unknown ticker, request quote and submit a trade |
| `client/components/trade-dialog/` | Edit/review/search workflow; validates inputs for feedback, then submits to the server for authoritative validation |
| `client/components/market-watch/`, `watch-button/` | Persist watchlist stars; one-share trade shortcuts use order API |
| `client/components/holdings-table/` | Current positions, average cost, latest price/value and expandable immutable purchase history |
| `client/components/order-history/` | Present status and expose cancellation event to its parent |
| `client/components/portfolio-summary/`, `portfolio-allocation/` | Display computed portfolio totals and allocation |
| `client/components/performance-chart/` | Current value and recorded return summary; its name does not imply a historical price series |
| `client/components/page-frame/`, `shared/components/` | Reusable layout, allocation chart and branding |
| Adjacent `.html` / `.css`, `src/styles.css` | Angular bindings, accessible controls and presentation; do not settle trades or store balances |
| `*.spec.ts`, `auth/testing.ts` | Unit/component fixtures and tests; fixtures are not live application data |
| `angular.json`, `tsconfig*.json`, `package*.json` | Angular/TypeScript compilation and locked dependency graph |
| `proxy.conf.json`, `nginx.conf`, `Dockerfile` | Development proxy and production static serving; map relative URLs to services |

Example change: a new field in the portfolio screen usually touches the Java
snapshot DTO/service, the banking API TypeScript shape, `PortfolioStore`, and the
display component. It does not require a new database field if it is derived from
existing facts. A new persisted fact also requires a SQL migration and tests.

## Authentication (`auth-server/`)

| Files | Role |
|---|---|
| `src/main.ts`, `app.module.ts` | Start Nest, compose modules, load validated environment and enable shutdown handling |
| `src/app.setup.ts` | Shared HTTP setup for app/tests: validation, errors, security headers, CORS, body limits and Swagger |
| `src/config/env.ts` | Runtime Zod validation; missing credentials/configuration fail at startup |
| `src/database/database.module.ts` | Shared PostgreSQL pool, idle-connection error handling and graceful shutdown |
| `src/auth/auth.module.ts`, `auth.controller.ts` | Dependency wiring and register/login/refresh/logout routes; request throttling |
| `src/auth/email.service.ts`, `password-reset.service.ts` | Resend SDK, auth-only durable email queue and password resets that preserve MFA; see [email service](email-service.md) |
| `src/auth/mfa.service.ts` | Mandatory TOTP enrollment/login/replacement, encrypted secrets, one-use challenges and recovery, user locks and attempt limits; see [MFA](mfa.md) |
| `src/auth/auth.service.ts` | Credential checks, session lifecycle, replay revocation and generic invalid-login errors |
| `src/auth/token.service.ts` | HS256 JWT contract shared with both Spring services; random refresh tokens and SHA-256 hashes |
| `src/auth/sessions.repository.ts` | Session/token queries; one connection/transaction for rotation |
| `src/users/users.repository.ts` | Normalized credential email lookup and user insertion with parameterized SQL |
| `src/auth/dto/` | Validated request and documented response contracts |
| `src/common/` | Structured errors and safe auth event logs without tokens/passwords |
| `src/health/health.controller.ts` | Liveness/readiness, including database reachability |
| `src/**/*.spec.ts`, `test/`, `vitest.config*.ts` | Unit and HTTP-level tests; inspect test configuration for mocked dependencies |
| `scripts/integration-test.sh`, `session-test.sh` | Live auth exercises that can add/revoke local test sessions; not required for a documentation edit |

Registration creates auth credentials with CLIENT role. The trading identity and
empty account are created later by the trading API using the signed UUID.

## Client trading backend (`backend/`)

Java paths below are under `src/main/java/com/avengers/endgame/`.

| Package / important classes | What to follow |
|---|---|
| `EndgameApplication` | Spring boot entry point scanning this service's packages |
| `security/SecurityConfig` | Verify HS256 JWT, time, issuer/audience and map roles; public catalogue/quotes versus protected commands |
| `session/CurrentUserService` | Resolve verified CLIENT identity, upsert local user, lock it to create one zero-cash account and check ownership |
| `account/` | Account entity, locking repository and DTO mapping; current controller uses `CurrentUserService`; older create helper is not the client onboarding path |
| `user/` | Trading identity and ADMIN-only user-management route; does not store auth credentials or issue JWTs |
| `bankaccount/BankAccountController`, `BankAccountService` | Resolve current user, check linked-bank ownership, settle simulated cash and return coherent portfolio snapshots |
| `bankaccount/TradingAccountSnapshot`, `PositionReturns` | Snapshot contract and average-cost accounting from actual fills; missing complete basis remains unknown |
| `transaction/` | Immutable deposit/withdrawal/dividend entities and repository; SQL builds linked cash ledger |
| `holding/` | Current per-account instrument quantities used by execution and snapshots; legacy profile controller is not used by normal client UI |
| `instrument/` | Catalogue mapping/list/create/lookup; `InstrumentService` verifies unknown tickers and commits discovery independently |
| `integration/pricing/client/` | `PricingApiClient` interface and Fauxnance HTTP adapter; no trading balances changed here |
| `integration/pricing/config/`, `dto/`, `exception/` | Provider URL/key/timeouts, JSON contract and provider failures |
| `order/controller/OrderController` | Client ownership and order/quote HTTP contracts |
| `order/dto/`, `domain/`, `mapper/` | Order terms and mutable state, immutable fills/evidence, enums and response mapping |
| `order/repository/` | Query open commitments, lock orders, append fills/evidence and load history |
| `order/validator/OrderValidator` | Validate fields/eligibility/resources while retaining account lock; return reservation and any observed quote |
| `order/service/OrderService` | Persist accepted order, amend allowed price, cancel and release reservation |
| `order/service/OrderExecutionWorker` | Poll persisted accepted orders, monitor cached conditions and retry deferred executions |
| `order/service/OrderExecutionService` | Fresh quote plus locked revalidation, rounding, cash/holdings/fill/status in one transaction |
| `order/service/QuoteCache`, `OrderQuoteService`, `QuoteValidationException` | Cached display versus fresh valid execution quotes; preserve invalid observations for audit |
| `order/service/OrderAuditRecorder` | Observed evidence joins source transaction; failed pricing attempt uses a separate transaction |
| `watchlist/` | User-scoped persisted stars and lock-protected repeated add/remove operations |
| `tradingcontrol/` | Authoritative ADMIN suspension commands; actor from verified JWT, state change and audit insertion in one transaction |
| `exception/` | Convert order/business validation failures into API errors |
| `src/main/resources/application.properties` | Database, provider, quote-cache and worker configuration |
| `src/test/`, `TEST_GUIDE.md` | Unit/HTTP/integration tests; H2 by default and optional real-PostgreSQL checks |

The PostgreSQL triggers in `DB/endgame_db.schema.sql` are part of execution's
behavior: Java commits business facts; SQL appends lifecycle, cash-ledger and
outbox records. Read both when changing the order flow.

## Internal backend (`internal-backend/`)

Java paths are under `src/main/java/com/avengers/internal/`.

| Files / package | Role |
|---|---|
| `InternalApplication`, resource properties | Boot independent process and provide `adminAnalytics` JDBC template over one reporting datasource |
| `security/StaffSecurityConfig`, `CurrentActor`, `CurrentUserId`, `CurrentToken` | JWT checks (issuer, `endgame-staff` audience, MFA proof) and route permissions; actor UUID/email only from the verified token; caller headers cannot choose actor |
| `admin/AdminController` | Client/account/order lookup, suspension forwarding and staff audit search |
| `admin/AdminLookupService`, `AdminLookupRepository` | Input bounds, named SQL parameters, reporting views and detail-view audit insertion |
| `admin/AdminEvidenceController` | Filtered trades, original timeline/pricing and downloadable recorded evidence |
| `admin/AdminAuditRepository`, `AdminAuditSink`, `AdminAuditEntry`, `AdminAction` | Append/search staff detail-view logs and represent audit actions |
| `admin/AdminCommands`, `TradingAdminClient` | HTTP boundary to trading; forward caller JWT, propagate command result and handle unavailable owner |
| `admin/*Dto`, enums, `AdminPage`, `AdminPageRequest`, `AdminSql`, filters | Service-local contract types, bounded pagination, SQL escaping/parameters; no trading entity dependency |
| `admin/AdminExceptionHandler`, `common/InternalExceptionHandler` | Staff validation/dependency failure responses |
| `common/Rows` | Convert JDBC columns and timestamps into consistent JSON fields |
| `analytics/AnalyticsController` | Freshness, latest attempted/published batch, dashboard registry and guest-token routes |
| `analytics/SupersetGateway` | Approved dashboard allowlist and service-side login/CSRF/guest-token exchange |
| `src/test/`, `pom.xml`, `Dockerfile`, `README.md` | Independent tests/build and service-specific setup |

The older `/admin/orders` lookup requires a client or symbol. The test UI uses
`/admin/trades`, whose richer filtering can list all orders with bounded pages.
See [the staff API contract](admin-analytics/frontend-api.md) before adding a screen.

## Staff test UI (`internal-frontend/`)

| File | Role |
|---|---|
| `admin.html`, `analyst.html` | Separate staff login documents and role-specific workspaces |
| `src/api.js` | Memory-only session, one shared rotating refresh request, API errors and authenticated downloads |
| `src/app.js` | Safe DOM rendering, role navigation, searches/actions and Superset SDK lifecycle; guards against stale async results |
| `src/style.css` | Responsive layout, tables, forms and dashboard frame |
| `vite.config.js`, `nginx.conf`, `Dockerfile` | Development 5174 proxy and Docker 8086 serving with auth/internal API forwarding |
| `tests/console.spec.js`, `playwright.config.js` | Isolated browser fixtures for roles, errors, commands, export, token refresh and mobile layout |
| `tests/live-stack.mjs` | Real disposable API/Superset browser integration; generated short-lived test JWTs |
| `README.md` | Login, startup, feature checklist and browser verification |

## Data pipeline and dashboards (`admin-analytics/`)

| File | Responsibility and connection |
|---|---|
| `pipeline/pipeline.py` | CLI for snapshot, publisher, consumer, scheduler and manual report; commits Kafka offset after destination commit |
| `pipeline/projection.py` | Version/type validation, event deduplication and SQL projections using stable source IDs |
| `pipeline/reports.py` | New York cutoff, heartbeat readiness, batch facts, count/cash reconciliation and atomic publication |
| `pipeline/tests/integration.py` | Real PostgreSQL projection/replay/rounding/cutoff checks |
| `pipeline/tests/stack-seed.sql`, `stack-check.py`, `http-check.py` | Disposable source facts, Kafka/report path and JWT/API/Superset assertions |
| `pipeline/requirements.txt`, `Dockerfile` | Pinned Python dependencies and shared runtime image for the three worker processes |
| `superset/superset_config.py` | Metadata connection, embedding/guest-token settings and origin policy |
| `superset/init.sh` | Superset metadata migrations, permission initialization and bootstrap entry point |
| `superset/bootstrap.py` | Initial users/roles, restricted dataset, three dashboards and registry IDs; preserves authored layouts on rerun |
| `superset/Dockerfile` | Pinned Superset image with PostgreSQL driver and project initialization/configuration |

## Deployment, configuration and persisted data

The live deployment is managed by ECS on EC2. See
[operations](../deployment/ecs/README.md): `tasks/` contains task definitions,
`images/` records pinned ECR digests, `state/` contains runtime/rollback references,
and `verification/` contains test and security evidence. PostgreSQL is in RDS;
Kafka uses its existing persistent host volume. Angular builds are in S3/CloudFront.

`docker-compose.yml` and the staff Compose file remain legacy deployment references.
Disposable local database/frontend stacks are defined in
`deployment/ci/ci.compose.yml` and
`deployment/admin-analytics/admin-analyst-ci.compose.yml`; the Jenkins verification
scripts use isolated project names, networks and storage. Do not run CI against RDS.

Application Dockerfiles build each service independently. `.dockerignore` keeps
local dependencies and environment files out of build contexts; `.gitignore`
excludes credentials and generated output. Root `.env.example` documents setting
names; live ECS services inject Secrets Manager references. The root Maven POM is
a build convenience rather than a shared application module.

## Verification and delivery

| Command / file | What it establishes |
|---|---|
| `mvn test -DJWT_SECRET=test-only-secret-at-least-thirty-two-characters` | Root reactor tests both independent Java services using test configuration |
| `python3 scripts/run-backend-postgres-tests.py` | Trading tests with actual PostgreSQL schema/constraints in a temporary database |
| `python3 scripts/generate-instrument-seed.py --check` | Canonical seed and generated fixture match |
| `scripts/instrument_seed.py` | Shared catalogue parser/UUID/symbol checks used by generator and schema verifier |
| `python3 scripts/verify-db-schemas.py` | Schema/fixture reruns in temporary databases; `--check-live` additionally compares live source structure |
| `python3 scripts/verify-admin-analytics.py` | Real reporting SQL projection/replay/report tests using disposable storage |
| `python3 scripts/verify-admin-stack.py --browser` | Disposable Kafka-to-report path, staff API authorization, Nginx and real embedded Superset chart query |
| Auth `npm test`, `npm run test:e2e`, `npm run build` | Unit tests, HTTP-level tests and Nest build |
| Client `npm test -- --watch=false`, `npm run build` | Angular unit/component tests and production build |
| Staff UI `npm test`, `npm run build` | Playwright fixtures and Vite build; install Chromium first |

Run each npm command inside its own project. Full-stack scripts require built
images and Docker; follow [staff setup](admin-analytics/setup.md#tests). Do not
infer SQL trigger correctness from H2-only success. Comments/docs alone normally
need syntax/link/diff checks; application changes also need their relevant suites.

`Jenkinsfile` currently accepts only `dev` → `main` PRs, generates root env values
from Jenkins credentials, invokes secret scanning, rebuilds the root stack and
prepares backend classes for SonarQube. The service verification stage lists
containers. The Java preparation uses `-DskipTests`, and Sonar errors are currently
tolerated. Separate staff checks and all unit suites are not yet wired into CI.
Its volume-removing cleanup belongs on disposable infrastructure.

`docs/endgame-api.yaml`, `docs/orders.yaml`, older README notes and `UML/` are
supporting design artifacts; generated Swagger/controller code is the current
endpoint reference. `docs/archive/admin-frontend-plan.md` preserves the historical staff frontend
handoff. The project guide and staff setup document the running local deployment rather than
assuming every older diagram is implemented.

For the latest constructor, validation and MVC exception-handling changes, see the
[Spring Boot review](spring-boot-review.md).

The shared report-time feature lives in staff `analytics/ReportScheduleController`,
`ReportScheduleService` and `ReportingClockConfig`, reporting
`integration.report_schedules`, Python `reports.configured_time`/`period` and
`pipeline.run_scheduler`, and the staff Reports schedule form.
`bash scripts/start-project.sh` starts configured client/staff stacks; it does not
create secrets or migrate existing databases.

PDF code: staff `exports/PdfDocument` renders paginated files, `PdfExportService`
reads published reports/audit records, and `PdfExportController` exposes protected
attachment routes. Shared order evidence lives in `admin/AdminEvidenceService`.

`python3 scripts/verify-staff-pdfs.py` starts the packaged staff API on a temporary
port against a disposable reporting database, checks actual PDF downloads and role
permissions, then stops the API and drops only its own database. Build the staff jar
first; `--classes` can instead use the last Maven test classpath during development.


## Presentation guide and current workspace names

See [presentation guide](presentation-guide.md) for Ultron (admin), J.A.R.V.I.S. (analyst), development logins, spread/return examples, PDF interpretation and the expanded 99-client / 2,540-fill demo. Staff development images use `:local`. Existing data is preserved; run the demo loader to add the extension.
