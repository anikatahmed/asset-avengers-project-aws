# Presenting Asset Avengers: Ultron and J.A.R.V.I.S.

## Start and demonstrate

From the repository root, configure the single `.env`, then run:

```bash
bash scripts/start-project.sh
bash scripts/load-demo-data.sh
```

The startup script defaults to the full stack (`--all`); `--client` and `--staff` select a subset. Use the `docker compose` plugin. Normal startup does not fund clients; the demo loader explicitly adds synthetic portfolios and publishes reports. All local staff images now use `:local` tags; rebuild after pulling these changes rather than using the old images.

| Workspace | URL on the Docker host | Development login |
|---|---|---|
| Client | http://localhost:8084 | cameron.demo@example.com |
| Ultron — administrator | http://localhost:8086/admin.html | david.admin@example.com |
| J.A.R.V.I.S. — analyst | http://localhost:8086/analyst.html | priya.analyst@example.com |

New fixture passwords are `EndgameDemo123!`. These identities live in the auth database. `DB/auth_db_test_data.sql` renames the two original development staff identities while keeping their UUIDs and passwords. Existing audit events retain the actor email recorded at the time. Existing passwords are never reset by the loader.

**Demos without an authenticator, on your own machine only.** Turn on the [development switch](mfa.md#development-switch), then use one of these accounts. No code is asked for.
- `dev.admin@example.com` for Ultron
- `dev.analyst@example.com` for J.A.R.V.I.S.
- `dev.superadmin@example.com` for Ultron with the **Staff** tab, which creates admins and analysts and shows each one-time temporary password once

The seeded staff above still require an authenticator.

When browsing from another machine, replace `localhost` with the Docker host IP. Keep `SUPERSET_PUBLIC_URL=auto`: dashboard URLs follow the staff page's hostname, using `SUPERSET_PORT`. Add the staff origin (for example `http://192.168.1.65:8086`) to `SUPERSET_EMBED_ORIGINS` in the root `.env`, then rerun the Superset initializer and service. Automatic hostname selection does not bypass the embedding origin allowlist.

## Explain a small negative return after buying

Say: “Our simulator buys at the ask and sells at the bid. We mark holdings at the provider's reference price. Those are different prices, so the spread can cause a small initial unrealized loss.”

Example: one AAPL share executes at ask **$342.04**, while the reference price is **$342.00** and bid is **$341.96**. The saved cost basis is $342.04; displayed value is $342.00; unrealized return is **−$0.04**. Selling at the unchanged bid would instead realize **−$0.08**. The reference price is not a guaranteed sale price. We have not established whether the provider defines `price` as last trade or midpoint.

Two purchases of one share at $100 and $110 produce two shares, $210 total cost and **$105 average cost per share**. With a $108 reference price, their value is $216 and unrealized return is $6. Total return adds realized gains/losses from previous sales to unrealized gains/losses on shares still held; deposits are not investment gains.

The trade dialog explains execution, timestamps and stale quotes. Expand a holding to see its quote timestamp and bid/ask; timestamps use Eastern Time (America/New_York), including daylight saving time. The watchlist also explains spread execution. Purchases share the same saved provider quotes as display and search. The browser refreshes display prices every 60 seconds, with a shared fifteen-minute server quote cache; portfolio/account data refreshes every three seconds while visible. These are not the same quote snapshot. Failed refreshes can retain the previous displayed price.

This simulator trades at any time using the provider’s latest available quote, including old closing prices and quotes marked stale. Submission and execution share the latest available quote from the fifteen-minute cache. Missing or invalid prices, mismatched symbols/currencies, missing timestamps and timestamps more than five seconds ahead cannot execute. Buys use the available ask and sells use the available bid; missing side prices are not replaced with the last-traded price. If the provider cannot return a usable quote, orders wait or fail validation. Only USD settlement is supported.

## Demonstrate Ultron

Say: “Ultron investigates copied trading evidence and sends deliberate administrative commands to the trading service. It does not edit the reporting copies of trades.”

1. Open Orders. Keep it visible while making a client trade: the list polls every three seconds, after the ingestion delay.
2. Open a filled order. Show lifecycle events, the original pricing evidence and the cash movement. Execution uses one database transaction for cash, holdings, fill and audit/outbox changes.
3. Download **audit PDF** for a readable investigation record. **Audit JSON** remains a separate machine-readable export.
4. Open Actions. Type `ca`, choose Cameron Kelly or Carol Jones, and enter a reason before applying a suspension. The selected account is explicit; changing the search clears the selection. Instrument actions still require an instrument ID.
5. Remove the suspension and download the staff audit PDF for the relevant UTC dates. Administrators' actions and investigation access are audited.
6. Optional, as a super admin: open **Staff**.
   - Create an analyst and copy the one-time temporary password.
   - Sign in as that analyst on the J.A.R.V.I.S. page: it must choose its own password, then set up an authenticator.
   - Back in Staff, disable the analyst: its next sign-in shows "This account is disabled".

## Demonstrate J.A.R.V.I.S. and the reports

Say: “J.A.R.V.I.S. works with published reporting batches, separate from execution. Streaming keeps copied evidence current; publication defines the cutoff used for the daily business report.”

1. Sign in to J.A.R.V.I.S. separately. Admin commands are unavailable to analysts.
2. Open Reports and select a populated date, or choose **Generate daily report now**. The normal daily schedule and manual publication both use the reporting worker.
3. Show gross traded notional, trade counts, active clients and instrument activity. Gross notional is the sum of executed cash amounts, not profit, cash balance or assets under management.
4. Download **report PDF**. It includes a branded header, confidentiality notice, USD summary, instrument activity, original batch/cutoff and methodology notes. It is a daily trading activity report, not a brokerage account statement or regulatory filing.
5. Search a client by first or last name to see their published activity. Report data can lag ingestion, and an already open dashboard may require reopening; chart caches can take 30 seconds.

Example: a $1,000 buy followed by a $1,100 sale contributes **$2,100 gross traded notional**, two fills and $100 realized profit before any other adjustments. Do not present the $2,100 as profit.

## Expanded demo data and persistence

The loader creates **99 demo clients**, **99 demo bank links**, **975 watchlist entries**, **2,540 fills**, **13 insufficient-cash rejected orders**, and **12 disputes** on a fresh database. Historical activity spans up to 90 days and fifteen symbols; 2,042 fills use fractional quantities. The original three portfolios remain. Extensions finish their buy/sell pairs with no holdings, allowing current cash-based A/B/C classes without invented market quotes. Four dedicated cash-only accounts demonstrate exact boundaries. Five additional clients are suspended for the Ultron workflow; seven synthetic staff audit events record the suspension examples. No pending orders are seeded, and loading makes no pricing-provider or email requests. See the demo walkthrough for login names and boundaries.

Additional login examples: `amelia.carter.demo@example.com`, `charlotte.chen.demo@example.com`, `priya.patel.demo@example.com`, and `zoe.zhang.demo@example.com`. All 24 identities are listed in `DB/demo/expanded-auth.sql`. Use `ca` or `ch` to demonstrate narrowing name suggestions.

`DB/demo/auth.sql` and `trading.sql` retain the original demonstration. `expanded-auth.sql` and `expanded-trading.sql` add the larger set with dedicated stable UUIDs and a per-client existence check. The extension works on an already loaded original demo; reruns do not overwrite later trades, deposits or account status. Old cancelled demo records remain historical if loaded by an earlier version; the current seed creates no cancellation example.

Authentication owns identity, names, password hashes and sessions. The trading database owns client accounts, cash, bank links, instruments, holdings, orders, permanent fills and audit/outbox records. UUIDs connect ownership across systems. Kafka projects these facts into the separate reporting database; reports are published from those copies. Refreshing the browser or logging out does not delete saved records. Ingestion failure does not undo a committed trade; the pipeline retries outside execution.

Use `bash scripts/stop-project.sh` and answer `no` to keep data. Answer `y` only when intentionally deleting all project data. For presentation, never describe synthetic fixtures as real clients or market execution.

## Verification

- Staff Java tests exercise PDF content, publication cutoff and access boundaries.
- Staff browser tests cover role separation, names, downloads, polling and aligned action controls.
- `python3 scripts/verify-demo-data.py` checks isolated PostgreSQL cash/ledger/holding reconciliation, safe reruns, projection and repeated publication without double counting.
- `python3 scripts/verify-staff-pdfs.py` checks actual PDF API responses and authorization using a disposable reporting database.

Client prices remain provider-dependent; a successful UI build does not prove live quote availability. Demo cash is synthetic, and the system currently trades USD instruments only.


Client names in orders and dashboards: Ultron displays `clientName` alongside order IDs in search results and order details; the same name is included in order PDF/JSON evidence. Superset uses `analytics.named_published_trades`, joining the current copied client directory to published facts. Its client activity table groups by both name and UUID, and charts/filters use a name-plus-ID label. For example, Cameron Kelly appears beside his client ID rather than as a UUID alone. Missing names show “Unknown client”; the UUID remains available. Names are current directory labels, not a claim about the person's name at the historical trade time. Enrichment does not change the publication cutoff or financial totals. Rerunning dashboard initialization upgrades prepared client charts and filters while preserving dashboard layouts.


## Client MFA choice and password recovery demonstration

Say: “Our shared NestJS service offers clients an optional authenticator checkbox at signup; staff and enrolled clients require an authenticator before receiving a session.
After signup or an existing user's first login, the UI shows required QR setup.
Later logins for enrolled clients and staff require the password and an authenticator or recovery code. Clients who skip MFA use a password. Our Spring
APIs check the JWT's signed MFA claim along with signature, issuer, audience and time,
then apply roles and account ownership.”

Example: Priya enters her seeded J.A.R.V.I.S. credentials, scans the required QR and
verifies the app's code. Privately save the recovery codes, then enter J.A.R.V.I.S..
After signing out, show that another login requires a code. Do not expose the QR,
manual secret or recovery codes in presentation screenshots.

Say: “Forgot password sends a single-use, expiring email code through Resend. Reset
changes the password and revokes refresh sessions, but the authenticator remains
required. Email verification at signup is intentionally off for dummy-email testing.”

Use simulated sender tests for dummy addresses. Real sending needs a permitted
Resend recipient and sender; one authorized live message was accepted by Resend and its recipient confirmed
inbox delivery.
Only the auth database stores MFA and reset data. See [MFA](mfa.md) and
[email service](email-service.md) for limits, fields and examples.

The asset-type extension adds closed reporting examples for all seven recognized categories. Four inactive `DEMO-*` instruments illustrate category filters; they do not implement specialized derivatives, bond or mutual-fund execution. See [all asset-type demo examples](demo-walkthrough.md#demonstrating-every-asset-type-filter).

Pricing request caps, saved-quote fallback, and configuration are documented in [Pricing cache and request budget](pricing-cache.md).
