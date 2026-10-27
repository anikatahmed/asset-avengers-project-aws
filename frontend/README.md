# Asset Avengers client UI

The [project guide](../docs/project-guide.md) explains the full request/data flow.
The [code map](../docs/code-map.md#client-angular-app-frontend) connects pages,
API adapters and shared state; [design decisions](../docs/design-decisions.md)
explains polling, token storage and server-owned trading state.

Angular implementation of the Asset Avengers client prototypes:

- `/client/overview`: summary cards, interactive performance chart, market watch, and top holdings.
- `/client/portfolio`: all holdings and asset-specific trade entry.
- `/client/orders`: session order history and an empty state.

From this directory, run `npm install` (if dependencies are missing), then `npm start`. Open http://localhost:4200. Use `npm run build` for a production build and `npm test -- --watch=false` for tests.

Background quote polling requests only distinct symbols held in the selected account
or across investment accounts, plus watched symbols. Loading the instrument
catalogue does not request a quote for every listed instrument. Search and trade
controls can request individual quotes on demand.

Client dropdowns share the `PolishedSelect` directive and global picker styles.
The selected option keeps its checkmark; only the hovered or keyboard-active option
gets a lime highlight. Disabled options stay muted. Native select semantics and
Angular form bindings are preserved, and browsers without customizable select
support keep their native picker. Import the directive in components with selects.

New trade and each holding's Trade button open a keyboard-accessible native dialog. Buy/sell orders support review, editing, cancellation, quantity validation, buying-power validation, and holdings validation. Confirmed simulated orders update the shared portfolio store and order history across routes. Refreshing resets the demo. Market Watch loads ticker choices from GET /instruments. Orders remain simulated with no live execution.

Design source: https://www.figma.com/design/FjP8vRiu8SvtS15xwqT9jQ?node-id=2-195 (Overview) and node 2:198 (Portfolio). Orders follows the saved interactive prototype because the Figma plan limit prevented retrieving node 2:199. The Chart.js canvas replaces the Figma chart image and offers hover tooltips, 1W/1M/3M/1Y ranges, and an accessible data table. Deterministic sample history is generated in `src/app/client/components/performance-chart/performance-data.ts`; the latest portfolio point follows the shared store. The benchmark is rebased to the portfolio opening value for each range. Historical data is illustrative, not live market data. Summary totals are calculated from the sample holdings rather than copying the inconsistent prototype totals. Only the Client role is implemented.

Component structure:

- `src/app/app.*`: root router outlet; `app.routes.ts` defines authentication routes and nested client routes.
- `src/app/client/layout/`: shared sidebar and account navigation, with scoped layout styles.
- `src/app/client/pages/`: Overview, Portfolio, and Orders pages, each in its own folder with its template.
- `src/app/client/components/`: one folder per client component; performance chart helpers and tests live with the chart.
- `src/app/client/state/`: portfolio store and its tests.
- `src/app/auth/pages/auth-page/`: login/signup page, template, styles, and tests.
- `src/app/auth/components/portfolio-preview/`: preview used by the auth page.
- `src/app/shared/components/`: brand logo and allocation chart, reused across features.
- `src/app/api/instruments/`: instrument API service, response model, and service tests.
- `src/styles.css`: shared design tokens, table/form styles, and responsive utilities.

Keep each component's TypeScript, template, styles, and tests together. Small inline templates and styles remain in the component file. App-root files are reserved for bootstrap configuration and routing.

Display components receive data through signal inputs and emit trade actions through outputs. PageFrame provides the shared heading, notification, and dialog orchestration. TradeDialog owns the form/review state and calls PortfolioStore; the store remains the single source of truth across routes. Auth pages are outside the client layout route.

Login and signup UI is available at /login and /signup; the root now opens login. These are explicitly labeled demo forms with email, required-field, minimum signup password length, and password confirmation validation. Credentials are never stored or transmitted, and no account is created or authenticated. Client routes remain publicly accessible for preview. Connect an authentication API before adding real account access or protected routes.

Market Watch uses the instrument API on localhost:8080 through the development proxy enabled by npm start. Start the backend separately and restart ng serve after changing proxy settings. The picker supports loading, error/retry, empty results, and ticker/company search. Instruments can be watched without changing holdings; prices remain illustrative where available, and other tickers show Price unavailable.
