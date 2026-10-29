/**
 * Shared client read model: server snapshots supply cash, positions, orders and stars;
 * quotes supply changing display values. Computed signals update all connected screens.
 * Financial writes go through API services, then snapshots reconcile the result.
 * Session/version counters prevent an older request overwriting a newer login or star change.
 */

import { computed, DestroyRef, Injectable, inject, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { EMPTY, Subject, catchError, exhaustMap, forkJoin, merge, tap, timer, timeout } from 'rxjs';
import { BankAccountApiService } from '../../api/bank-accounts/bank-account-api.service';
import { AccountApiService } from '../../api/accounts/account-api.service';
import { HttpClient } from '@angular/common/http';
import { Instrument } from '../../api/instruments/instrument';
import { InstrumentApiService } from '../../api/instruments/instrument-api.service';
import { QuoteApiService } from '../../api/quotes/quote-api.service';
import { OrderType } from '../../api/orders/order';

export interface Asset {
  symbol: string;
  name: string;
  price: number;
  change: number;
  shares: number;
  cost: number;
  costKnown?: boolean;
  instrumentId: string;
  purchases?: import('../../api/bank-accounts/bank-account-api.service').Purchase[];
  quoteAsOf?: string;
  quoteBid?: number;
  quoteAsk?: number;
  quoteStale?: boolean;
  quoteMarketState?: string;
}
export type Side = 'buy' | 'sell';
export interface HistoryPoint { at: string; accountValue: number | null; holdingsCost: number | null; cash: number; event: string; }

export interface Order {
  accountId?: string;
  id: string | number;
  symbol: string;
  side: Side;
  quantity: number;
  total: number | null;
  status: string;
  submittedAt?: string;
  executionPrice?: number | null;
  finalizedAt?: string | null;
  updatedAt?: string;
  rejectionReason?: string | null;
  type?: OrderType;
  limitPrice?: number | null;
  stopPrice?: number | null;
  stopTriggered?: boolean;
}
const round = (value: number) => Math.round(value * 100) / 100;

@Injectable({ providedIn: 'root' })
export class PortfolioStore {
  private readonly instrumentApi = inject(InstrumentApiService);
  private readonly banking = inject(BankAccountApiService);
  private readonly refreshRequests = new Subject<void>();
  private readonly quoteApi = inject(QuoteApiService);
  private readonly accountApi = inject(AccountApiService);
  private readonly destroyRef = inject(DestroyRef);

  readonly history = signal<HistoryPoint[]>([]);
  readonly historyIncomplete = signal(false);
  readonly historyError = signal('');
  readonly historyLoading = signal(false);
  private historyPending = false;
  refreshHistory(): void {
    if (this.historyPending) return;
    const version = this.sessionVersion;
    this.historyPending = true; this.historyLoading.set(true);
    this.http.get<{ points: HistoryPoint[]; incomplete: boolean }>('/api/v1/bank-accounts/history')
      .pipe(timeout(15000), takeUntilDestroyed(this.destroyRef)).subscribe({
        next: result => { if (version !== this.sessionVersion) return; this.history.set(result.points); this.historyIncomplete.set(result.incomplete); this.historyError.set(''); this.historyPending=false; this.historyLoading.set(false); },
        error: () => { if (version !== this.sessionVersion) return; this.historyError.set('Unable to load saved history.'); this.historyPending=false; this.historyLoading.set(false); },
      });
  }

  readonly instruments = signal<Instrument[]>([]);
  readonly assets = signal<Asset[]>([]);
  readonly aggregateAssets = signal<Asset[]>([]);
  readonly aggregateCash = signal(0);
  readonly aggregateCashBalance = signal(0);
  readonly aggregateRealizedReturn = signal(0);
  readonly aggregateWatchedSymbols = signal<string[]>([]);
  readonly aggregateLoading = signal(false);
  readonly accountId = signal<string | null>(null);
  readonly accountSwitchPending = signal(false);
  private readonly http = inject(HttpClient);
  private watchPending = false;
  private sessionVersion = 0;
  private accountSelectionVersion = 0;
  private watchVersion = 0;
  readonly cash = signal(0); // Start with $0 - users must deposit money
  readonly orders = signal<Order[]>([]);
  readonly cashBalance = signal(0);
  readonly portfolioError = signal<string | null>(null);
  readonly lastPortfolioUpdatedAt = signal<number | null>(null);
  readonly lastPricesUpdatedAt = signal<number | null>(null);
  private readonly failedQuotes = new Set<string>();
  readonly delayedPriceSymbols = signal<string[]>([]);
  private catalogueFailed = false;
  private catalogueLoading = false;
  readonly pricesLoading = signal(false);
  readonly pricesError = signal<string | null>(null);

  private readonly watched = signal<string[]>([]);
  readonly watchedSymbols = this.watched.asReadonly();
  readonly watchlist = computed(() => this.assets().filter(asset => this.watched().includes(asset.symbol)));

  startSession(): void {
    this.resetState();
    this.initializePrices();
    this.refreshPortfolio().pipe(takeUntilDestroyed(this.destroyRef)).subscribe();
  }

  resetSession(): void {
    this.resetState();
  }

  private resetState(): void {
    this.sessionVersion++; this.watchVersion++; this.watchPending = false;
    this.accountSelectionVersion++;
    this.history.set([]); this.historyError.set(''); this.historyIncomplete.set(false); this.historyPending=false;
    this.lastPortfolioUpdatedAt.set(null); this.lastPricesUpdatedAt.set(null);
    this.portfolioError.set(null); this.pricesError.set(null); this.failedQuotes.clear(); this.delayedPriceSymbols.set([]);
    this.quoting.clear(); this.catalogueFailed = false; this.catalogueLoading = false;
    this.assets.set([]); this.watched.set([]); this.orders.set([]);
    this.aggregateAssets.set([]); this.aggregateCash.set(0); this.aggregateCashBalance.set(0);
    this.aggregateRealizedReturn.set(0); this.aggregateLoading.set(false);
    this.aggregateWatchedSymbols.set([]);
    this.cash.set(0); this.cashBalance.set(0); this.realizedReturn.set(0); this.accountId.set(null); this.accountSwitchPending.set(false);
    this.historyLoading.set(false);
  }

  // Subscribe from the client layout so polling stops on logout/navigation out of the client area.
  liveUpdates() {
    return merge(timer(1000, 3000), this.refreshRequests).pipe(
      exhaustMap(() => document.hidden ? EMPTY : this.refreshPortfolio().pipe(
        tap(() => this.refreshAggregatePortfolio()),
      )),
    );
  }

  livePrices() {
    return timer(0, 60000).pipe(tap(() => { if (!document.hidden) { if (this.catalogueFailed) this.initializePrices(); else this.fetchQuotesForAssets(this.instruments()); } }));
  }

  requestRefresh(): void {
    this.refreshRequests.next();
    this.refreshAggregatePortfolio();
  }

  retryUpdates(): void {
    this.requestRefresh();
    if (this.catalogueFailed) this.initializePrices();
    else this.fetchQuotesForAssets(this.instruments());
  }

  selectAccount(accountId: string): void {
    if (accountId === this.accountId()) return;
    this.accountSelectionVersion++;
    this.accountSwitchPending.set(true);
    this.assets.set([]);
    this.orders.set([]);
    this.cash.set(0);
    this.cashBalance.set(0);
    this.realizedReturn.set(0);
    this.accountId.set(accountId);
    this.refreshPortfolio().subscribe();
  }

  private refreshPortfolio() {
    const sessionVersion = this.sessionVersion;
    const accountSelectionVersion = this.accountSelectionVersion;
    const selectedAccountId = this.accountId();
    const watchVersion = this.watchVersion;
    return this.banking.getTradingAccount(selectedAccountId ?? undefined).pipe(
      timeout(15000),
      tap(account => {
        if (sessionVersion !== this.sessionVersion || accountSelectionVersion !== this.accountSelectionVersion) return;
        this.accountId.set(account.accountId);
        this.accountSwitchPending.set(false);
        if (!this.watchPending && watchVersion === this.watchVersion) this.watched.set(account.watchedSymbols ?? []);
        this.cashBalance.set(account.cashBalance);
        this.cash.set(account.availableCash);
        this.realizedReturn.set(account.realizedReturn ?? 0);
        const positions = new Map(account.holdings.map(position => [position.symbol, position]));
        const knownSymbols = new Set(this.assets().map(asset => asset.symbol));
        const added = account.holdings.filter(position => !knownSymbols.has(position.symbol));
        const newlyHeld = account.holdings.some(position => position.quantity > 0
          && !this.holdings().some(asset => asset.symbol === position.symbol));
        this.assets.update(assets => [
          ...assets.map(asset => ({ ...asset, shares: positions.get(asset.symbol)?.quantity ?? 0,
            instrumentId: positions.get(asset.symbol)?.instrumentId || asset.instrumentId,
            cost: positions.get(asset.symbol)?.averageCost ?? 0,
            costKnown: positions.get(asset.symbol)?.averageCost != null,
            purchases: positions.get(asset.symbol)?.purchases ?? [] })),
          ...added.map(position => ({ symbol: position.symbol, name: position.name,
            shares: position.quantity, instrumentId: position.instrumentId, price: 0, cost: position.averageCost ?? 0, costKnown: position.averageCost != null, change: 0, purchases: position.purchases ?? [] })),
        ]);
        if (added.length || newlyHeld) this.fetchQuotesForAssets(this.instruments());
        const symbols = new Map([
          ...this.instruments().map(instrument => [instrument.instrumentId, instrument.symbol] as const),
          ...account.holdings.map(position => [position.instrumentId, position.symbol] as const),
        ]);
        this.replaceOrders(account.orders.map(order => ({ id: order.orderId, accountId: order.accountId,
          symbol: symbols.get(order.instrumentId) ?? this.orders().find(value => value.id === order.orderId)?.symbol ?? 'Unknown',
          side: order.orderSide, quantity: order.quantity, status: order.status, submittedAt: order.submittedAt,
          total: order.price == null ? null : order.price * order.quantity,
          executionPrice: order.price, finalizedAt: order.finalizedAt,
          updatedAt: order.updatedAt, rejectionReason: order.rejectionReason,
          type: order.orderType, limitPrice: order.limitPrice, stopPrice: order.stopPrice,
          stopTriggered: order.stopTriggered,
        })));
        this.lastPortfolioUpdatedAt.set(Date.now());
        this.portfolioError.set(null);
      }),
      catchError(() => {
        if (sessionVersion !== this.sessionVersion) return EMPTY;
        this.portfolioError.set('Unable to refresh your portfolio. Retrying…');
        return EMPTY;
      }),
    );
  }

  refreshAggregatePortfolio(): void {
    if (this.aggregateLoading()) return;
    const accounts = this.accountApi.accounts();
    if (!accounts.length) {
      this.aggregateAssets.set([]);
      this.aggregateCash.set(0);
      this.aggregateCashBalance.set(0);
      this.aggregateRealizedReturn.set(0);
      this.aggregateWatchedSymbols.set([]);
      return;
    }
    this.aggregateLoading.set(true);
    const version = this.sessionVersion;
    forkJoin(accounts.map(account => this.banking.getTradingAccount(account.accountId).pipe(timeout(15000)))).subscribe({
      next: snapshots => {
        if (version !== this.sessionVersion) return;
        const assets = new Map<string, Asset>();
        // A database snapshot supplies quantities/costs, not market prices. Keep
        // the latest quote rather than resetting every refresh to a $0 valuation.
        const quoted = new Map([...this.assets(), ...this.aggregateAssets()]
          .filter(asset => Number.isFinite(asset.price) && asset.price > 0)
          .map(asset => [asset.symbol, asset]));
        let cash = 0;
        let cashBalance = 0;
        let realizedReturn = 0;
        const watchedSymbols = new Set<string>();
        for (const snapshot of snapshots) {
          cash += snapshot.availableCash;
          cashBalance += snapshot.cashBalance;
          realizedReturn += snapshot.realizedReturn ?? 0;
          for (const symbol of snapshot.watchedSymbols ?? []) watchedSymbols.add(symbol);
          for (const position of snapshot.holdings) {
            const current = assets.get(position.symbol);
            const shares = current?.shares ?? 0;
            const nextShares = shares + position.quantity;
            const knownCost = position.averageCost != null && (current?.costKnown ?? true);
            const lastQuote = quoted.get(position.symbol);
            assets.set(position.symbol, {
              ...lastQuote,
              symbol: position.symbol,
              name: position.name,
              instrumentId: position.instrumentId,
              shares: nextShares,
              cost: knownCost && nextShares > 0
                ? ((current?.cost ?? 0) * shares + (position.averageCost ?? 0) * position.quantity) / nextShares
                : 0,
              costKnown: knownCost,
              price: lastQuote?.price ?? 0,
              change: lastQuote?.change ?? 0,
              purchases: [...(current?.purchases ?? []), ...(position.purchases ?? [])],
            });
          }
        }
        this.aggregateAssets.set([...assets.values()].filter(asset => asset.shares > 0));
        this.aggregateCash.set(cash);
        this.aggregateCashBalance.set(cashBalance);
        this.aggregateRealizedReturn.set(realizedReturn);
        this.aggregateWatchedSymbols.set([...watchedSymbols].sort());
        this.aggregateLoading.set(false);
        if (this.aggregateHoldings().some(asset => !Number.isFinite(asset.price) || asset.price <= 0))
          this.fetchQuotesForAssets(this.aggregateAssets());
      },
      error: error => {
        if (version !== this.sessionVersion) return;
        console.error('[Portfolio] Failed to load aggregate accounts:', error);
        this.aggregateLoading.set(false);
      },
    });
  }

  private initializePrices(): void {
    if (this.catalogueLoading) return;
    this.catalogueLoading = true;
    this.pricesLoading.set(true);

    console.log('[Portfolio] Initializing prices...');
    const sessionVersion = this.sessionVersion;
    this.instrumentApi.getAllInstruments()
      .pipe(timeout(15000), takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: (instruments) => {
          if (sessionVersion !== this.sessionVersion) return;
          this.catalogueFailed = false; this.catalogueLoading = false;
          console.log('[Portfolio] Fetched instruments:', instruments);
          this.instruments.set(instruments);
          this.assets.update(assets => [...assets, ...instruments.filter(instrument =>
            !assets.some(asset => asset.symbol === instrument.symbol)).map(instrument => ({
              symbol: instrument.symbol, name: instrument.name, instrumentId: instrument.instrumentId,
              shares: 0, cost: 0, costKnown: false, price: 0, change: 0,
            }))]);
          this.fetchQuotesForAssets(instruments);
        },
        error: (error) => {
          if (sessionVersion !== this.sessionVersion) return;
          this.catalogueFailed = true; this.catalogueLoading = false;
          console.error('[Portfolio] Failed to load instruments:', error);
          this.pricesError.set('Failed to load instrument data. Using cached prices.');
          this.pricesLoading.set(false);
        }
      });
  }

  private readonly quoting = new Set<string>();

  private fetchQuotesForAssets(instruments: Pick<Instrument, 'symbol' | 'instrumentId'>[]): void {
    const symbols = new Set([
      ...this.holdings().map(asset => asset.symbol),
      ...this.aggregateHoldings().map(asset => asset.symbol),
      ...this.watchedSymbols(),
      ...this.aggregateWatchedSymbols(),
    ]);
    // Newly purchased symbols may appear in holdings before the instrument catalogue refreshes.
    const targets = new Map([...instruments, ...this.assets(), ...this.aggregateHoldings()]
      .map(asset => [asset.symbol, asset.instrumentId]));
    const sessionVersion = this.sessionVersion;
    for (const symbol of [...this.failedQuotes]) if (!symbols.has(symbol)) this.failedQuotes.delete(symbol);
    this.delayedPriceSymbols.update(values => values.filter(symbol => symbols.has(symbol)));
    for (const symbol of symbols) {
      if (this.quoting.has(symbol)) continue;
      this.quoting.add(symbol);
      this.quoteApi.getQuote(symbol).pipe(timeout(15000), takeUntilDestroyed(this.destroyRef)).subscribe({
        next: quote => {
          if (sessionVersion !== this.sessionVersion) return;
          if (Number.isFinite(quote.price) && quote.price > 0) {
            this.assets.update(assets => assets.map(asset => asset.symbol === symbol ? {
              ...asset, price: quote.price, change: quote.changePercent ?? asset.change, quoteAsOf: quote.asOf,
              quoteBid: quote.bid, quoteAsk: quote.ask, quoteStale: quote.stale, quoteMarketState: quote.marketState,
              instrumentId: targets.get(symbol) || asset.instrumentId,
            } : asset));
            this.aggregateAssets.update(assets => assets.map(asset => asset.symbol === symbol ? {
              ...asset, price: quote.price, change: quote.changePercent ?? asset.change, quoteAsOf: quote.asOf,
              quoteBid: quote.bid, quoteAsk: quote.ask, quoteStale: quote.stale, quoteMarketState: quote.marketState,
            } : asset));
            this.failedQuotes.delete(symbol);
            this.delayedPriceSymbols.update(values => quote.stale
              ? [...new Set([...values, symbol])].sort() : values.filter(value => value !== symbol));
          } else this.failedQuotes.add(symbol);
          this.quoting.delete(symbol);
          this.updatePriceStatus();
          this.pricesLoading.set(false);
        },
        error: () => {
          if (sessionVersion !== this.sessionVersion) return;
          this.failedQuotes.add(symbol);
          this.quoting.delete(symbol);
          this.pricesLoading.set(false);
          this.pricesError.set('Unable to refresh some prices. Showing the last available quotes.');
        },
      });
    }
    if (!this.quoting.size) this.pricesLoading.set(false);
    this.updatePriceStatus();
  }

  private updatePriceStatus(): void {
    if (this.catalogueFailed) return;
    if (this.failedQuotes.size) {
      this.pricesError.set('Some prices could not be refreshed. Displayed values may be out of date.');
    } else if (!this.quoting.size) {
      this.pricesError.set(null);
      if (this.holdings().length || this.watchedSymbols().length) this.lastPricesUpdatedAt.set(Date.now());
    }
  }

  isWatched(symbol: string): boolean {
    return this.watched().includes(symbol);
  }

  toggleWatch(symbol: string): void {
    if (this.watchPending) return;
    this.watchPending = true;
    const sessionVersion = this.sessionVersion;
    const url = '/api/v1/me/watchlist/' + encodeURIComponent(symbol);
    const request = this.isWatched(symbol) ? this.http.delete<string[]>(url) : this.http.put<string[]>(url, {});
    request.pipe(takeUntilDestroyed(this.destroyRef)).subscribe({
      next: symbols => { if (sessionVersion !== this.sessionVersion) return; this.watchVersion++; this.watched.set(symbols); this.watchPending = false; },
      error: () => { if (sessionVersion !== this.sessionVersion) return; this.watchPending = false; this.portfolioError.set('Unable to save your watchlist. Please try again.'); },
    });
  }

  readonly holdings = computed(() => this.assets().filter((a) => a.shares > 0));
  readonly valuationReady = computed(() => this.holdings().every(asset => Number.isFinite(asset.price) && asset.price > 0));
  readonly value = computed(() =>
    round(this.cashBalance() + this.assets().reduce((sum, a) => sum + a.shares * a.price, 0)),
  );
  readonly costBasis = computed(() => this.assets().reduce((sum, a) => sum + a.shares * a.cost, 0));
  readonly realizedReturn = signal(0);
  readonly totalReturn = computed(() =>
    round(
      this.realizedReturn() +
        this.assets().reduce((sum, a) => sum + (a.costKnown === false || !Number.isFinite(a.price) || a.price <= 0
          ? 0 : a.shares * (a.price - a.cost)), 0),
    ),
  );
  readonly aggregateHoldings = computed(() => this.aggregateAssets().filter(asset => asset.shares > 0));
  readonly aggregateValuationReady = computed(() => this.aggregateHoldings().every(asset => Number.isFinite(asset.price) && asset.price > 0));
  readonly aggregateValue = computed(() =>
    round(this.aggregateCashBalance() + this.aggregateAssets().reduce((sum, asset) => sum + asset.shares * asset.price, 0)),
  );
  readonly aggregateTotalReturn = computed(() =>
    round(this.aggregateRealizedReturn() + this.aggregateAssets().reduce((sum, asset) =>
      sum + (asset.costKnown === false || !Number.isFinite(asset.price) || asset.price <= 0
        ? 0 : asset.shares * (asset.price - asset.cost)), 0)),
  );

  validate(symbol: string, side: Side, quantity: number, price?: number): string {
    // Match the trading database's NUMERIC(18,4) quantity precision. Check the
    // decimal representation so valid values such as 0.0003 survive JS rounding.
    if (!Number.isFinite(quantity) || quantity < 0.0001 || quantity >= 1e14 ||
        !/^\d+(?:\.\d{1,4})?$/.test(String(quantity))) {
      return 'Enter at least 0.0001 shares, with no more than 4 decimal places.';
    }
    let asset = this.assets().find((a) => a.symbol === symbol);

    // If asset doesn't exist and we're trying to sell, reject
    if (!asset && side === 'sell') {
      return `You don't hold any shares of ${symbol}.`;
    }

    // If asset doesn't exist, it's a new stock (only allow buy)
    if (!asset) {
      // For new stocks, still validate cash available to trade if price is provided
      if (side === 'buy' && price && round(quantity * price) > this.cash()) {
        return 'This order exceeds your cash available to trade.';
      }
      return ''; // Will be created on trade if price is loaded
    }

    if (side === 'buy' && asset && round(quantity * (price ?? asset.price)) > this.cash())
      return 'This order exceeds your cash available to trade.';
    if (side === 'sell' && quantity > asset.shares)
      return `You hold ${asset.shares} shares of ${symbol}.`;
    return '';
  }

  replaceOrders(orders: Order[]): void {
    this.orders.set(orders);
  }

  addOrder(order: Order): void {
    this.orders.update(orders => [order, ...orders.filter(existing => existing.id !== order.id)]);
  }

  updateOrderStatus(orderId: string, status: string): void {
    this.updateOrder(orderId, { status });
  }

  updateOrder(orderId: string, changes: Partial<Omit<Order, 'id'>>): void {
    this.orders.update(orders => orders.map(order =>
      order.id === orderId ? { ...order, ...changes } : order,
    ));
  }

}
