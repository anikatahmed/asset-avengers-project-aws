import { TestBed } from '@angular/core/testing';
import { HttpTestingController, HttpClientTestingModule } from '@angular/common/http/testing';
import { Asset, PortfolioStore } from './portfolio.store';
import { AccountApiService } from '../../api/accounts/account-api.service';
import { Instrument } from '../../api/instruments/instrument';
import { InstrumentApiService } from '../../api/instruments/instrument-api.service';
import { QuoteApiService } from '../../api/quotes/quote-api.service';
import { of, throwError } from 'rxjs';
import { afterEach, vi } from 'vitest';
const TEST_ACCOUNT_ID = '20000000-0000-0000-0000-000000000003';

describe('Market watch', () => {
  let store: PortfolioStore;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [
        PortfolioStore,
        {
          provide: InstrumentApiService,
          useValue: { getAllInstruments: () => of([]) }
        },
        {
          provide: QuoteApiService,
          useValue: { getQuote: () => of({}) }
        }
      ]
    });
    store = TestBed.inject(PortfolioStore);
    store.startSession();
  });

  it('keeps price warnings until every failed quote recovers and retains the account timestamp on failure', () => {
    const http = TestBed.inject(HttpTestingController);
    let failing = true;
    vi.spyOn(TestBed.inject(QuoteApiService), 'getQuote').mockImplementation(symbol =>
      symbol === 'MSFT' && failing ? throwError(() => new Error('Unavailable')) : of({ price: 100, stale: false } as any));
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({
      accountId: TEST_ACCOUNT_ID, cashBalance: 800, availableCash: 800,
      holdings: ['MSFT','AAPL'].map(symbol => ({ symbol, name: symbol, instrumentId: symbol, quantity: 1 })), orders: [],
    });
    expect(store.pricesError()).toBeTruthy(); // AAPL succeeded after MSFT failed.
    expect(store.lastPricesUpdatedAt()).toBeNull();
    const updated = store.lastPortfolioUpdatedAt();
    expect(updated).not.toBeNull();
    const subscription = store.liveUpdates().subscribe();
    store.requestRefresh();
    http.expectOne(`/api/v1/bank-accounts/trading-account?accountId=${TEST_ACCOUNT_ID}`).flush({}, { status: 503, statusText: 'Unavailable' });
    expect(store.lastPortfolioUpdatedAt()).toBe(updated);
    expect(store.portfolioError()).toBeTruthy();
    failing = false;
    store.retryUpdates();
    expect(store.pricesError()).toBeNull();
    expect(store.lastPricesUpdatedAt()).not.toBeNull();
    http.expectOne(`/api/v1/bank-accounts/trading-account?accountId=${TEST_ACCOUNT_ID}`).flush({ accountId: TEST_ACCOUNT_ID, cashBalance: 800, availableCash: 800, holdings: [], orders: [] });
    expect(store.portfolioError()).toBeNull();
    subscription.unsubscribe(); http.verify();
  });

  it('separates delayed provider quotes from refresh failures and resets update timestamps for a new session', () => {
    const http = TestBed.inject(HttpTestingController);
    vi.spyOn(TestBed.inject(QuoteApiService), 'getQuote').mockReturnValue(of({ price: 100, stale: true } as any));
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({ accountId: TEST_ACCOUNT_ID, cashBalance: 800, availableCash: 800,
      holdings: [{symbol:'AAPL', name:'Apple', instrumentId:'apple', quantity:1}], orders:[] });
    expect(store.pricesError()).toBeNull();
    expect(store.delayedPriceSymbols()).toEqual(['AAPL']);
    store.startSession();
    expect(store.delayedPriceSymbols()).toEqual([]);
    expect(store.lastPortfolioUpdatedAt()).toBeNull();
    expect(store.lastPricesUpdatedAt()).toBeNull();
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({}, {status:503,statusText:'Unavailable'});
    expect(store.portfolioError()).toBeTruthy();
    expect(store.lastPortfolioUpdatedAt()).toBeNull();
    http.verify();
  });

  it('restores saved purchase history and average cost on a new session', () => {
    const http = TestBed.inject(HttpTestingController);
    const purchases = [{ fillId: 'first', acquiredAt: '2026-10-14T12:00:00Z',
      quantity: 2, pricePaid: 100, totalCost: 200 }];
    const snapshot = { accountId: TEST_ACCOUNT_ID, cashBalance: 800, availableCash: 800,
      holdings: [{ instrumentId: 'apple', symbol: 'AAPL', name: 'Apple', quantity: 2,
        averageCost: 100, purchases }], orders: [] };
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush(snapshot);
    expect(store.holdings()[0].purchases).toEqual(purchases);
    expect(store.holdings()[0].cost).toBe(100);
    store.startSession();
    expect(store.holdings()).toEqual([]);
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush(snapshot);
    expect(store.holdings()[0].purchases).toEqual(purchases);
    expect(store.holdings()[0].cost).toBe(100);
    http.verify();
  });

  it('restores buying power from the same account used for deposits and orders', () => {
    const http = TestBed.inject(HttpTestingController);
    const request = http.expectOne(req =>
      req.url === '/api/v1/bank-accounts/trading-account'
);
    request.flush({ accountId: TEST_ACCOUNT_ID, cashBalance: 1250, availableCash: 1250, holdings: [], orders: [] });
    expect(store.cash()).toBe(1250);
    expect(store.validate('AAPL', 'buy', 1)).toBe('');
    http.verify();
  });

  it('loads holdings from the selected investment account', () => {
    const http = TestBed.inject(HttpTestingController);
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({
      accountId: TEST_ACCOUNT_ID, cashBalance: 800, availableCash: 800,
      holdings: [], orders: [],
    });

    const selectedAccountId = '30000000-0000-0000-0000-000000000004';
    store.selectAccount(selectedAccountId);
    const request = http.expectOne(req =>
      req.url === '/api/v1/bank-accounts/trading-account'
      && req.params.get('accountId') === selectedAccountId
    );
    request.flush({
      accountId: selectedAccountId, cashBalance: 450, availableCash: 450,
      holdings: [{ instrumentId: 'apple', symbol: 'AAPL', name: 'Apple', quantity: 3, averageCost: 100 }],
      orders: [],
    });

    expect(store.accountId()).toBe(selectedAccountId);
    expect(store.cash()).toBe(450);
    expect(store.holdings().map(asset => asset.symbol)).toEqual(['AAPL']);
    expect(store.holdings()[0].shares).toBe(3);
    http.verify();
  });

  it('updates buying power and holdings after accepted, bought and sold snapshots', () => {
    const http = TestBed.inject(HttpTestingController);
    const url = (req: import('@angular/common/http').HttpRequest<unknown>) =>
      req.url === '/api/v1/bank-accounts/trading-account';
    http.expectOne(url).flush({ accountId: TEST_ACCOUNT_ID, cashBalance: 1000,
      availableCash: 1000, holdings: [], orders: [] });
    const subscription = store.liveUpdates().subscribe();
    const snapshot = (cashBalance: number, availableCash: number, quantity: number) => {
      store.requestRefresh();
      http.expectOne(url).flush({ accountId: TEST_ACCOUNT_ID, cashBalance, availableCash,
        holdings: [{ instrumentId: 'apple', symbol: 'AAPL', name: 'Apple', quantity }], orders: [] });
    };
    snapshot(1000, 800, 0); // Accepted buy reserves cash but does not add shares.
    expect(store.cash()).toBe(800);
    expect(store.holdings()).toHaveLength(0);
    snapshot(800, 800, 2);
    expect(store.holdings().find(asset => asset.symbol === 'AAPL')?.shares).toBe(2);
    snapshot(900, 900, 1);
    expect(store.cash()).toBe(900);
    expect(store.holdings().find(asset => asset.symbol === 'AAPL')?.shares).toBe(1);
    snapshot(1000, 1000, 0);
    expect(store.holdings()).toHaveLength(0);
    store.requestRefresh();
    http.expectOne(url).flush({}, { status: 503, statusText: 'Unavailable' });
    expect(store.cash()).toBe(1000);
    expect(store.portfolioError()).toContain('Retrying');
    snapshot(1100, 1100, 0);
    expect(store.cash()).toBe(1100);
    expect(store.portfolioError()).toBeNull();
    subscription.unsubscribe();
    http.verify();
  });

  it('refreshes portfolio value and return with market prices and preserves realized profit after selling', () => {
    vi.useFakeTimers();
    const http = TestBed.inject(HttpTestingController);
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({
      accountId: TEST_ACCOUNT_ID, cashBalance: 800, availableCash: 700, realizedReturn: 10,
      holdings: [{ symbol: 'AAPL', name: 'Apple', instrumentId: 'apple', quantity: 2, averageCost: 100 }], orders: [],
    });
    let price = 110;
    vi.spyOn(TestBed.inject(QuoteApiService), 'getQuote').mockImplementation(() => of({ price, changePercent: 0 } as any));
    const prices = store.livePrices().subscribe();
    let updates: { unsubscribe(): void } | undefined;
    try {
      vi.advanceTimersByTime(0);
      expect(store.value()).toBe(1020); // Uses full cash, including the reserved $100.
      expect(store.totalReturn()).toBe(30);
      price = 120;
      vi.advanceTimersByTime(60000);
      expect(store.value()).toBe(1040);
      expect(store.totalReturn()).toBe(50);
      updates = store.liveUpdates().subscribe();
      store.requestRefresh();
      http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({
        accountId: TEST_ACCOUNT_ID, cashBalance: 1040, availableCash: 1040, realizedReturn: 50,
        holdings: [{ symbol: 'AAPL', name: 'Apple', instrumentId: 'apple', quantity: 0, averageCost: 0 }], orders: [],
      });
      expect(store.value()).toBe(1040);
      expect(store.totalReturn()).toBe(50);
      http.verify();
    } finally { prices.unsubscribe(); updates?.unsubscribe(); vi.useRealTimers(); }
  });

  it('does not apply a previous login response after switching users', () => {
    const http = TestBed.inject(HttpTestingController);
    store.startSession();
    const requests = http.match(req => req.url === '/api/v1/bank-accounts/trading-account');
    expect(requests).toHaveLength(2);
    requests[1].flush({ accountId: 'new-user-account', cashBalance: 500, availableCash: 500,
      holdings: [], orders: [], watchedSymbols: ['IBM'] });
    requests[0].flush({ accountId: 'old-user-account', cashBalance: 100, availableCash: 100,
      holdings: [], orders: [], watchedSymbols: ['AAPL'] });
    expect(store.accountId()).toBe('new-user-account');
    expect(store.cash()).toBe(500);
    expect(store.watchedSymbols()).toEqual(['IBM']);
    http.verify();
  });

  it('clears the previous user state when logging out before a new user has an account', () => {
    const http = TestBed.inject(HttpTestingController);
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({
      accountId: TEST_ACCOUNT_ID, cashBalance: 1250, availableCash: 1250, holdings: [], orders: [],
    });
    expect(store.cash()).toBe(1250);

    store.resetSession();

    expect(store.cash()).toBe(0);
    expect(store.cashBalance()).toBe(0);
    expect(store.accountId()).toBeNull();
    expect(store.holdings()).toEqual([]);
    expect(store.orders()).toEqual([]);
    http.verify();
  });

  it('saves stars in the backend and restores them from the next account snapshot', () => {
    const http = TestBed.inject(HttpTestingController);
    http.expectOne(req => req.url === '/api/v1/bank-accounts/trading-account').flush({
      accountId: TEST_ACCOUNT_ID, cashBalance: 1000, availableCash: 1000, holdings: [], orders: [], watchedSymbols: ['IBM'],
    });
    expect(store.watchedSymbols()).toEqual(['IBM']);
    store.toggleWatch('AAPL');
    const save = http.expectOne('/api/v1/me/watchlist/AAPL');
    expect(save.request.method).toBe('PUT');
    save.flush(['IBM', 'AAPL']);
    expect(store.watchedSymbols()).toEqual(['IBM', 'AAPL']);
    store.toggleWatch('IBM');
    const remove = http.expectOne('/api/v1/me/watchlist/IBM');
    expect(remove.request.method).toBe('DELETE');
    remove.flush(['AAPL']);
    expect(store.watchedSymbols()).toEqual(['AAPL']);
    expect(store.holdings()).toEqual([]);
    expect(store.cash()).toBe(1000);
    http.verify();
  });
});

describe('Portfolio quote selection', () => {
  let store: PortfolioStore;
  let http: HttpTestingController;
  const quoteUrl = '/api/v1/orders/quote/symbol/';
  const catalogue: Instrument[] = Array.from({ length: 100 }, (_, index) => ({
    instrumentId: `instrument-${index}`,
    symbol: index === 0 ? 'AAPL' : `UNHELD${index}`,
    name: `Instrument ${index}`,
    securityType: 'equity',
    exchange: 'NASDAQ',
    currency: 'USD',
    isin: null,
    active: true,
  }));
  const asset = (symbol: string, shares = 1): Asset => ({
    symbol, name: symbol, instrumentId: symbol, shares, cost: 80, price: 0, change: 0,
  });
  const snapshot = {
    accountId: TEST_ACCOUNT_ID, cashBalance: 1000, availableCash: 1000,
    realizedReturn: 0, holdings: [], orders: [], watchedSymbols: [],
  };
  const flushQuotes = (symbols: string[]) => {
    const requests = http.match(request => request.url.startsWith(quoteUrl));
    expect(requests.map(request => request.request.url.slice(quoteUrl.length)).sort())
      .toEqual([...symbols].sort());
    requests.forEach(request => request.flush({ price: 100, changePercent: 0, stale: false }));
  };

  beforeEach(() => {
    vi.useFakeTimers();
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [{
        provide: InstrumentApiService,
        useValue: { getAllInstruments: () => of(catalogue) },
      }],
    });
    store = TestBed.inject(PortfolioStore);
    http = TestBed.inject(HttpTestingController);
    store.startSession();
  });

  afterEach(() => {
    vi.useRealTimers();
    http.verify();
  });

  it('does not quote the catalogue at login or on polling when nothing is held or watched', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush(snapshot);
    const prices = store.livePrices().subscribe();
    try {
      vi.advanceTimersByTime(30000);
      flushQuotes([]);
    } finally {
      prices.unsubscribe();
    }
  });

  it('quotes only distinct held and watched symbols across accounts, including symbols outside the catalogue', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush({
      ...snapshot, watchedSymbols: ['IBM', 'AAPL'],
    });
    store.assets.update(assets => [...assets.filter(value => value.symbol !== 'AAPL'), asset('AAPL')]);
    store.aggregateAssets.set([asset('AAPL', 2), asset('MSFT'), asset('NEW'), asset('SOLD', 0)]);
    store.aggregateWatchedSymbols.set(['IBM', 'SHOP']);
    const expected = ['AAPL', 'MSFT', 'NEW', 'IBM', 'SHOP'];
    const prices = store.livePrices().subscribe();
    try {
      vi.advanceTimersByTime(0);
      flushQuotes(expected);
      expect(store.aggregateHoldings().every(value => value.price === 100)).toBe(true);
      vi.advanceTimersByTime(60000);
      flushQuotes(expected);
    } finally {
      prices.unsubscribe();
    }
  });

  it('requests aggregate-only holdings immediately after loading account snapshots and on later polls', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush(snapshot);
    TestBed.inject(AccountApiService).accounts.set(['first', 'second'].map(accountId => ({
      accountId, accountName: accountId, accountType: 'Individual Brokerage',
      cashBalance: 1000, suspended: false, deactivated: false, updatedAt: '2026-10-22T12:00:00Z',
    })));
    store.refreshAggregatePortfolio();
    for (const accountId of ['first', 'second']) {
      http.expectOne(request => request.url === '/api/v1/bank-accounts/trading-account'
        && request.params.get('accountId') === accountId).flush({
        ...snapshot,
        accountId,
        watchedSymbols: ['IBM'],
        holdings: [{
          instrumentId: 'msft', symbol: 'MSFT', name: 'Microsoft', quantity: 1, averageCost: 80,
        }],
      });
    }
    flushQuotes(['MSFT', 'IBM']);
    expect(store.aggregateHoldings()[0].shares).toBe(2);
    expect(store.aggregateValue()).toBe(2200);
    const prices = store.livePrices().subscribe();
    try {
      vi.advanceTimersByTime(0);
      flushQuotes(['MSFT', 'IBM']);
      vi.advanceTimersByTime(60000);
      flushQuotes(['MSFT', 'IBM']);
    } finally {
      prices.unsubscribe();
    }
  });

  it('does not count an unpriced $5000 purchase as a loss and preserves its last quote', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush(snapshot);
    TestBed.inject(AccountApiService).accounts.set([{
      accountId: TEST_ACCOUNT_ID, accountName: 'Brokerage', accountType: 'Individual Brokerage',
      cashBalance: 5000, suspended: false, deactivated: false, updatedAt: '2026-10-29T12:00:00Z',
    }]);
    const purchased = { ...snapshot, cashBalance: 5000, availableCash: 5000,
      holdings: [{ instrumentId: 'msft', symbol: 'MSFT', name: 'Microsoft', quantity: 10, averageCost: 500 }] };
    store.refreshAggregatePortfolio();
    http.expectOne(request => request.params.get('accountId') === TEST_ACCOUNT_ID).flush(purchased);
    expect(store.aggregateHoldings()).toHaveLength(1);
    expect(store.aggregateValuationReady()).toBe(false);
    expect(store.aggregateTotalReturn()).toBe(0);
    http.expectOne(`${quoteUrl}MSFT`).flush({ price: 505, stale: false });
    expect(store.aggregateValuationReady()).toBe(true);
    expect(store.aggregateTotalReturn()).toBe(50);
    store.refreshAggregatePortfolio();
    http.expectOne(request => request.params.get('accountId') === TEST_ACCOUNT_ID).flush(purchased);
    expect(store.aggregateHoldings()[0].price).toBe(505);
    expect(store.aggregateTotalReturn()).toBe(50);
    http.match(request => request.url.startsWith(quoteUrl)).forEach(request =>
      request.flush({}, { status: 503, statusText: 'Unavailable' }));
    expect(store.aggregateTotalReturn()).toBe(50);
  });

  it('refreshes overview holdings when an asynchronous trade fills after submission', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush(snapshot);
    TestBed.inject(AccountApiService).accounts.set([{
      accountId: TEST_ACCOUNT_ID, accountName: 'Brokerage', accountType: 'Individual Brokerage',
      cashBalance: 1000, suspended: false, deactivated: false, updatedAt: '2026-10-29T12:00:00Z',
    }]);
    const updates = store.liveUpdates().subscribe();
    try {
      vi.advanceTimersByTime(1000);
      http.expectOne(request => request.params.get('accountId') === TEST_ACCOUNT_ID).flush(snapshot);
      http.expectOne(request => request.params.get('accountId') === TEST_ACCOUNT_ID).flush({ ...snapshot,
        holdings: [{ instrumentId: 'msft', symbol: 'MSFT', name: 'Microsoft', quantity: 1, averageCost: 100 }] });
      expect(store.aggregateHoldings().map(position => position.symbol)).toEqual(['MSFT']);
      flushQuotes(['MSFT']);
    } finally { updates.unsubscribe(); }
  });

  it('does not duplicate in-flight requests and stops quoting positions after they are removed', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush(snapshot);
    store.aggregateAssets.set([asset('MSFT')]);
    const prices = store.livePrices().subscribe();
    vi.advanceTimersByTime(0);
    const pending = http.expectOne(`${quoteUrl}MSFT`);
    const concurrentPrices = store.livePrices().subscribe();
    try {
      vi.advanceTimersByTime(0);
      flushQuotes([]);
      pending.flush({ price: 100, stale: false });
      store.aggregateAssets.set([]);
      vi.advanceTimersByTime(60000);
      flushQuotes([]);
    } finally {
      prices.unsubscribe();
      concurrentPrices.unsubscribe();
    }
  });

  it('retries failed necessary quotes without requesting unrelated catalogue symbols', () => {
    http.expectOne('/api/v1/bank-accounts/trading-account').flush(snapshot);
    store.aggregateAssets.set([asset('MSFT')]);
    const prices = store.livePrices().subscribe();
    try {
      vi.advanceTimersByTime(0);
      http.expectOne(`${quoteUrl}MSFT`).flush({}, { status: 502, statusText: 'Bad Gateway' });
      expect(store.pricesError()).toBeTruthy();
      vi.advanceTimersByTime(60000);
      flushQuotes(['MSFT']);
      expect(store.pricesError()).toBeNull();
    } finally {
      prices.unsubscribe();
    }
  });
});
