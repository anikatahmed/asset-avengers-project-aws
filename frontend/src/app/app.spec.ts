import { AccountApiService } from './api/accounts/account-api.service';
import { TestBed } from '@angular/core/testing';
import { signal, WritableSignal } from '@angular/core';
import { provideRouter } from '@angular/router';
import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { RouterTestingHarness } from '@angular/router/testing';
import { routes } from './app.routes';
import { Asset, PortfolioStore } from './client/state/portfolio.store';
import { InstrumentApiService } from './api/instruments/instrument-api.service';
import { AuthService } from './auth/auth.service';
import { NEVER, of } from 'rxjs';

describe('Saved client workspace', () => {
  beforeEach(() => TestBed.configureTestingModule({ providers: [
    provideRouter(routes), provideHttpClient(), provideHttpClientTesting(),
    { provide: AuthService, useValue: { isLoggedIn: signal(true), mfaChallenge: signal(null), roles: signal(['CLIENT']),
      email: signal('client@example.com'), fullName: signal('Cameron Kelly'), claims: signal(null), logout: () => undefined } },
    { provide: AccountApiService, useValue: { accounts: signal([{accountId:'account'}]), getAccounts: () => of([{accountId:'account'}]), clear: () => undefined } },
    { provide: InstrumentApiService, useValue: { getAllInstruments: () => of([]) } },
    { provide: PortfolioStore, useValue: {
      startSession: () => undefined, liveUpdates: () => NEVER, livePrices: () => NEVER,
      refreshAggregatePortfolio: () => undefined, aggregateLoading: signal(false),
      aggregateHoldings: signal([]), aggregateWatchedSymbols: signal([]), aggregateCashBalance: signal(0),
      aggregateCash: signal(0), aggregateValue: signal(0), aggregateTotalReturn: signal(0),
      history: signal([]), historyIncomplete: signal(false), historyError: signal(''), historyLoading: signal(false), refreshHistory: () => undefined,
      delayedPriceSymbols: signal([]), portfolioError: signal(null), pricesError: signal(null), lastPortfolioUpdatedAt: signal(null), lastPricesUpdatedAt: signal(null), retryUpdates: () => undefined,
      requestRefresh: () => undefined, assets: signal([]), instruments: signal([]), watchedSymbols: signal([]),
      holdings: signal([]), orders: signal([]), cash: signal(0), cashBalance: signal(0),
      value: signal(0), totalReturn: signal(0), valuationReady: signal(true), aggregateValuationReady: signal(true),
      accountId: signal('account'), accountSwitchPending: signal(false), isWatched: () => false,
    } },
  ] }));
  it('starts without invented holdings or performance history', async () => {
    const harness = await RouterTestingHarness.create('/client/overview');
    const text = harness.routeNativeElement!.textContent!;
    expect(text).toContain('No holdings yet');
    expect(text).toContain('Your watchlist is empty');
    expect(text).not.toContain('Joanna');
    expect(text).not.toContain('Sample data');
    expect(text).not.toContain('Illustrative history');
  });
  it('shows stale account data across pages and removes the warning after recovery', async () => {
    const store = TestBed.inject(PortfolioStore);
    const harness = await RouterTestingHarness.create('/client/overview');
    store.lastPortfolioUpdatedAt.set(Date.now());
    store.portfolioError.set('Unable to refresh');
    harness.detectChanges();
    expect(harness.routeNativeElement!.textContent).toContain('Some information may be out of date');
    expect(harness.routeNativeElement!.textContent).toContain('Account last updated');
    await harness.navigateByUrl('/client/portfolio');
    expect(harness.routeNativeElement!.textContent).toContain('Some information may be out of date');
    store.portfolioError.set(null); harness.detectChanges();
    expect(harness.routeNativeElement!.querySelector('.data-warning')).toBeNull();
  });
  it('shows pending valuation rather than a fabricated loss while keeping the held asset count', async () => {
    const store = TestBed.inject(PortfolioStore);
    const ready = store.aggregateValuationReady as WritableSignal<boolean>;
    const holdings = store.aggregateHoldings as WritableSignal<Asset[]>;
    ready.set(false);
    holdings.set([{ symbol: 'MSFT', name: 'Microsoft', shares: 10,
      cost: 500, costKnown: true, price: 0, change: 0, instrumentId: 'msft' }]);
    const harness = await RouterTestingHarness.create('/client/overview');
    const metrics = harness.routeNativeElement!.querySelector('app-portfolio-summary')!;
    expect(metrics.textContent).toContain('Awaiting prices');
    expect(metrics.textContent).not.toContain('-$5,000');
    expect(metrics.querySelectorAll('.value')[3].textContent?.trim()).toBe('1');
    ready.set(true);
    harness.detectChanges();
    expect(metrics.textContent).not.toContain('Awaiting prices');
  });
  it('shows quiet delayed-price information only on pages that use quotes', async () => {
    const store = TestBed.inject(PortfolioStore);
    store.delayedPriceSymbols.set(['REPL']);
    const harness = await RouterTestingHarness.create('/client/overview');
    expect(harness.routeNativeElement!.textContent).toContain('Prices may be delayed for REPL');
    expect(harness.routeNativeElement!.querySelector('.data-warning')).toBeNull();
    await harness.navigateByUrl('/client/bank-accounts');
    expect(harness.routeNativeElement!.querySelector('.price-notice')).toBeNull();
    await harness.navigateByUrl('/client/market-watch');
    expect(harness.routeNativeElement!.querySelector('.price-notice')).toBeTruthy();
    store.delayedPriceSymbols.set([]); harness.detectChanges();
    expect(harness.routeNativeElement!.querySelector('.price-notice')).toBeNull();
  });
  it('keeps client navigation off the login screen', async () => {
    const harness = await RouterTestingHarness.create('/client/portfolio');
    expect(harness.routeNativeElement?.querySelector('nav')).toBeTruthy();
    await harness.navigateByUrl('/login');
    expect(harness.routeNativeElement?.querySelector('nav')).toBeNull();
    expect(harness.routeNativeElement?.querySelector('[aria-roledescription="carousel"]')).toBeTruthy();
    expect(harness.routeNativeElement?.textContent).toContain('Illustrative data');
  });
});
