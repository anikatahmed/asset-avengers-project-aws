# Trade Explorer: charts and typed filters without SQL

Trade Explorer is a separate Superset dashboard and reusable dataset. It joins
published trade fills with permitted client names, account labels and current
portfolio valuation. Analysts do not need to write a join to use those fields.
Existing embedded dashboards and analyst-authored charts remain in place.

## Open it

1. Sign in to the analyst application.
2. Choose **Open Superset workspace** to complete the existing SSO handoff.
3. In Superset, open **Dashboards → Trade Explorer**.
4. Type a value in a filter's search field, select the matching option, then apply
   the filters. For example, choose First name **Cameron** and Ticker **AAPL**.
5. Select the report-date range you want. The initial setting includes all
   published dates rather than hiding historical demo data.

Direct dashboard path after sign-in:
https://analytics.assetavengers.top/superset/dashboard/asset-trade-explorer/

Searchable dashboard filters include first name, last name, client identity,
ticker, asset type, buy/sell side, investment account/type and current portfolio
class/valuation quality. Typing searches available values; it is not a natural
language query box. Unknown names/tickers do not become new financial records.

## Create your own chart

1. Choose **Charts → + Chart**.
2. Select the dataset **asset_avengers_trade_explorer** and a chart type.
3. Choose the grouping and metric. For example, group by Ticker and use
   **Traded amount (USD)** or **Trade count**.
4. In Explore's **Filters**, select any included column, a simple operator, and
   type/select its value. Add First name equals Cameron and Ticker equals AAPL.
5. For numeric conditions, use a simple filter such as Trade amount greater than
   or equal to 1000. For partial text matching, use LIKE with a pattern such as
   Cam%. These are structured filters; SQL expressions are not required.
6. Run/update the chart, save it under your own name and add it to your dashboard.

Multiple filters normally combine with AND; multiple choices inside one selection
filter match any selected value. First name Cameron is an exact field match and
does not accidentally match a surname or a different first name such as Camille.

## Available data and meanings

| Group | Fields |
| --- | --- |
| Client | First name, last name, full name, client ID and identity label |
| Account | Account ID/name/type and account label |
| Trade | Ticker, asset type, side, quantity, execution price, cash amount, fill/order/instrument IDs |
| Time | Published report date, execution/order timestamps, readable Eastern placement time, order year/month |
| Current portfolio | Class, size band, valuation quality, value, cash, holdings value, missing-price count, oldest quote |
| Report | Published batch ID and trade status (filled) |

The dataset contains **one row per published fill**, not one row per client or day.
Rejected orders and unpublished fills are excluded. A person with no published
fills will not appear merely because they have an auth account.

Traded amount is gross USD buy/sell volume, not profit, revenue, deposits or net
cash flow. Shares/quantity totals should be grouped by instrument; quantities
across unrelated assets are not one meaningful share total.

Current portfolio fields repeat on every fill for that client. **Do not sum them
across trade rows.** They describe the latest reporting valuation, not portfolio
value at the historical trade date. Missing/stale prices remain accurately marked.
No email, bank credentials, authentication tables or password fields are included.

## Implementation and maintenance

- Source: `admin-analytics/superset/trade_explorer.py`.
- SQL reads `analytics.named_published_trades`, `reporting.client_directory` and
  `reporting.client_portfolios` through the existing read-only reporting login.
- Native Superset filters and Explore's structured filters build the filtered
  queries. No new application filter parser or arbitrary SQL endpoint is added.
- The reporting database schema and grants do not change.
- A separate additive dataset/dashboard is created. Existing charts, dashboard
  layouts, SSO settings and metadata schema are not replaced.
- Stable object UUIDs make setup repeatable. Name collisions or a changed managed
  SQL definition cause a review error instead of overwriting unrelated content.
- Only the existing ReportingSqlAuthor role receives the new dataset permission;
  embedded guests do not receive access to the new workspace.

For new environments, the reviewed bootstrap also prepares this workspace. For an
existing environment, the one-shot `prepare_trade_explorer.py` entry point finds
the existing reporting connection/owner and prepares only Trade Explorer. It does
not run Superset initialization, migrations or the broad dashboard bootstrap.
Apply it from a matching Superset 6 environment after reviewing current metadata
and taking a configuration backup. Do not put it in the web service startup command.

AWS deployment applies these records to the existing persistent Superset metadata
using the reviewed Python source. It requires no production container restart or
new infrastructure. The Dockerfile includes the maintenance source for future
image builds; changing metadata does not imply an image digest changed.

## Verification

Superset-independent regression tests run with:

```bash
python3 -m unittest discover -s admin-analytics/pipeline/tests -p 'test_*.py' -v
```

For real Superset ORM/API and read-only PostgreSQL checks, first build a Superset
6 image from the repository or use the matching tested image. Then run:

```bash
python3 scripts/verify-trade-explorer.py --image asset-analytics-superset:local
```

The helper creates uniquely named local containers with generated test settings,
no published ports and no external network. It never reads root .env or connects
to RDS. It removes its own containers afterward and retains logs in its temporary
report directory. Production cannot be used as its fixture target.

The integration tests verify one-row-per-fill joins, exact first-name/ticker
filters, numeric and LIKE conditions, safe handling of quoted filter values,
non-admin dataset access, saving a chart without SQL, read-only database grants,
and preservation of existing/authored layouts on rerun.

Browser verification additionally checks native filter typing and chart responses.
After AWS deployment, the same reporting-reader query and analyst-role chart API
are checked against real published data, and existing chart/dashboard fingerprints
are compared with their pre-change values. A framework-authenticated analyst-role
probe is not a fresh external SSO login; use the existing SSO button for a personal
end-to-end check.

Deployment evidence: [Trade Explorer verification](../../deployment/ecs/verification/trade-explorer-verification.json).
