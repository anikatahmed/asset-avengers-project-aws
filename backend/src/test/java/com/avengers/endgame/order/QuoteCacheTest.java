package com.avengers.endgame.order;
import com.avengers.endgame.order.service.QuoteCache;
import com.avengers.endgame.integration.pricing.client.PricingApiClient;
import com.avengers.endgame.integration.pricing.dto.QuoteResponse;
import org.junit.jupiter.api.Test;
import java.time.*;
import java.math.BigDecimal;
import static org.mockito.Mockito.*;
import static org.junit.jupiter.api.Assertions.*;
class QuoteCacheTest {
 @Test void transientFailureRetriesAtThirtySecondsInsteadOfFiveMinutes() {
    var pricing = mock(PricingApiClient.class);
    var clock = mock(Clock.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    when(clock.instant()).thenReturn(now);
    var observation = quote(now);
    when(pricing.getQuote("AAPL"))
        .thenThrow(new com.avengers.endgame.integration.pricing.exception.PricingApiException("timeout"))
        .thenReturn(observation);
    var cache = new QuoteCache(pricing, Duration.ofMinutes(15), clock);
    assertThrows(com.avengers.endgame.integration.pricing.exception.PricingApiException.class, () -> cache.search("AAPL"));
    when(clock.instant()).thenReturn(now.plusSeconds(29));
    assertThrows(com.avengers.endgame.integration.pricing.exception.PricingApiException.class, () -> cache.search("AAPL"));
    verify(pricing, times(1)).getQuote("AAPL");
    when(clock.instant()).thenReturn(now.plusSeconds(30));
    assertSame(observation, cache.search("AAPL"));
    verify(pricing, times(2)).getQuote("AAPL");
 }
 @Test void unusableQuoteRetriesAtThirtySeconds() {
    var pricing = mock(PricingApiClient.class);
    var clock = mock(Clock.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    when(clock.instant()).thenReturn(now);
    var observation = quote(now);
    when(pricing.getQuote("AAPL")).thenReturn(null).thenReturn(observation);
    var cache = new QuoteCache(pricing, Duration.ofMinutes(15), clock);
    assertNull(cache.search("AAPL"));
    when(clock.instant()).thenReturn(now.plusSeconds(29));
    assertThrows(com.avengers.endgame.integration.pricing.exception.PricingApiException.class, () -> cache.search("AAPL"));
    verify(pricing, times(1)).getQuote("AAPL");
    when(clock.instant()).thenReturn(now.plusSeconds(30));
    assertSame(observation, cache.search("AAPL"));
 }
 @Test void providerRateLimitStillHonorsItsLongerRetryDeadline() {
    var pricing = mock(PricingApiClient.class);
    var clock = mock(Clock.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    when(clock.instant()).thenReturn(now);
    when(pricing.getQuote("AAPL"))
        .thenThrow(new com.avengers.endgame.integration.pricing.exception.PricingRateLimitException(null, now.plusSeconds(120)))
        .thenReturn(quote(now));
    var cache = new QuoteCache(pricing, Duration.ofMinutes(15), clock);
    assertThrows(com.avengers.endgame.integration.pricing.exception.PricingRateLimitException.class, () -> cache.search("AAPL"));
    when(clock.instant()).thenReturn(now.plusSeconds(30));
    assertThrows(com.avengers.endgame.integration.pricing.exception.PricingApiException.class, () -> cache.search("AAPL"));
    verify(pricing, times(1)).getQuote("AAPL");
    when(clock.instant()).thenReturn(now.plusSeconds(120));
    assertNotNull(cache.search("AAPL"));
    verify(pricing, times(2)).getQuote("AAPL");
 }
 @Test void displaysSearchesAndTradesShareOneQuoteUntilTtlExpires() {
    var pricing = mock(PricingApiClient.class);
    var clock = mock(Clock.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    when(clock.instant()).thenReturn(now);
    var quote = new QuoteResponse("AAPL", BigDecimal.TEN, BigDecimal.TEN, BigDecimal.TEN, null,
        "USD", null, null, null, now, "OPEN", false, "test");
    when(pricing.getQuote("AAPL")).thenReturn(quote);
    var cache = new QuoteCache(pricing, Duration.ofMinutes(15), clock);
    assertSame(quote, cache.display("aapl"));
    assertSame(quote, cache.display("AAPL"));
    verify(pricing, times(1)).getQuote("AAPL");
    cache.fresh("AAPL");
    verify(pricing, times(1)).getQuote("AAPL");
    cache.search("AAPL");
    verify(pricing, times(1)).getQuote("AAPL");
    when(clock.instant()).thenReturn(now.plusSeconds(899));
    cache.display("AAPL");
    verify(pricing, times(1)).getQuote("AAPL");
    when(clock.instant()).thenReturn(now.plusSeconds(901));
    cache.display("AAPL");
    verify(pricing, times(2)).getQuote("AAPL");
 }
 @Test void markStorageFailureDoesNotBreakQuoteOrTriggerExtraProviderCalls() {
    var pricing = mock(PricingApiClient.class);
    var events = mock(org.springframework.context.ApplicationEventPublisher.class);
    var quote = new QuoteResponse("AAPL", BigDecimal.TEN, BigDecimal.TEN, BigDecimal.TEN, null,
        "USD", null, null, null, Instant.now(), "OPEN", false, "test");
    when(pricing.getQuote("AAPL")).thenReturn(quote);
    doThrow(new IllegalStateException("test failure")).when(events).publishEvent(quote);
    var cache = new QuoteCache(pricing, Duration.ofMinutes(1), events);
    assertSame(quote,cache.display("AAPL"));
    assertSame(quote,cache.display("AAPL"));
    verify(pricing,times(1)).getQuote("AAPL");
    verify(events,times(1)).publishEvent(quote);
 }
 @Test void simultaneousRequestsForOneSymbolShareOneProviderCall() throws Exception {
    var pricing = mock(PricingApiClient.class);
    var entered = new java.util.concurrent.CountDownLatch(1);
    var release = new java.util.concurrent.CountDownLatch(1);
    var observation = quote(Instant.now());
    when(pricing.getQuote("AAPL")).thenAnswer(call -> { entered.countDown(); release.await(3, java.util.concurrent.TimeUnit.SECONDS); return observation; });
    var cache = new QuoteCache(pricing, Duration.ofMinutes(10));
    try (var pool = java.util.concurrent.Executors.newFixedThreadPool(2)) {
        var first = pool.submit(() -> cache.display("AAPL"));
        assertTrue(entered.await(2, java.util.concurrent.TimeUnit.SECONDS));
        var second = pool.submit(() -> cache.fresh("AAPL"));
        release.countDown();
        assertSame(observation, first.get(3, java.util.concurrent.TimeUnit.SECONDS));
        assertSame(observation, second.get(3, java.util.concurrent.TimeUnit.SECONDS));
        verify(pricing, times(1)).getQuote("AAPL");
    } finally { release.countDown(); }
 }
 @Test void persistedQuoteSurvivesRestartAndProviderFailure() {
    var pricing = mock(PricingApiClient.class);
    var store = mock(com.avengers.endgame.order.service.SavedQuoteRepository.class);
    var budget = mock(com.avengers.endgame.order.service.PricingRequestBudget.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    var quote = quote(now.minusSeconds(86400));
    when(store.find("AAPL")).thenReturn(java.util.Optional.of(
        new com.avengers.endgame.order.service.SavedQuoteRepository.SavedQuote(quote, now.minusSeconds(700))));
    when(budget.reserve(false)).thenReturn(true);
    when(pricing.getQuote("AAPL")).thenThrow(new com.avengers.endgame.integration.pricing.exception.PricingApiException("offline"));
    var restarted = new QuoteCache(pricing, Duration.ofMinutes(10), Clock.fixed(now, ZoneOffset.UTC), store, budget, null);
    var fallback = restarted.fresh("AAPL");
    assertTrue(fallback.stale());
    assertEquals("saved-cache", fallback.source());
    assertEquals(quote.ask(), fallback.ask());
    assertEquals(quote.asOf(), fallback.asOf());
    restarted.display("AAPL");
    verify(pricing, times(1)).getQuote("AAPL");
 }
 @Test void budgetExhaustionUsesSavedPricesWithoutCallingProvider() {
    var pricing = mock(PricingApiClient.class);
    var store = mock(com.avengers.endgame.order.service.SavedQuoteRepository.class);
    var budget = mock(com.avengers.endgame.order.service.PricingRequestBudget.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    when(store.find("AAPL")).thenReturn(java.util.Optional.of(
        new com.avengers.endgame.order.service.SavedQuoteRepository.SavedQuote(quote(now), now.minusSeconds(700))));
    var cache = new QuoteCache(pricing, Duration.ofMinutes(10), Clock.fixed(now, ZoneOffset.UTC), store, budget, null);
    assertTrue(cache.display("AAPL").stale());
    assertTrue(cache.fresh("AAPL").stale());
    verifyNoInteractions(pricing);
 }
 @Test void dailyProviderLimitPausesBudgetAndKeepsLastQuote() {
    var pricing = mock(PricingApiClient.class);
    var store = mock(com.avengers.endgame.order.service.SavedQuoteRepository.class);
    var budget = mock(com.avengers.endgame.order.service.PricingRequestBudget.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    Instant reset = Instant.parse("2026-10-15T00:00:00Z");
    when(store.find("AAPL")).thenReturn(java.util.Optional.of(
        new com.avengers.endgame.order.service.SavedQuoteRepository.SavedQuote(quote(now), now.minusSeconds(700))));
    when(budget.reserve(false)).thenReturn(true);
    when(pricing.getQuote("AAPL")).thenThrow(new com.avengers.endgame.integration.pricing.exception.PricingRateLimitException(null, reset));
    var cache = new QuoteCache(pricing, Duration.ofMinutes(10), Clock.fixed(now, ZoneOffset.UTC), store, budget, null);
    assertTrue(cache.display("AAPL").stale());
    cache.fresh("AAPL");
    verify(budget).pauseUntil(reset);
    verify(pricing, times(1)).getQuote("AAPL");
 }
 @Test void interactiveSearchUsesReservedBudgetAndNeverInventsMissingPrices() {
    var pricing = mock(PricingApiClient.class);
    var store = mock(com.avengers.endgame.order.service.SavedQuoteRepository.class);
    var budget = mock(com.avengers.endgame.order.service.PricingRequestBudget.class);
    Instant now = Instant.parse("2026-10-14T12:00:00Z");
    when(store.find("AAPL")).thenReturn(java.util.Optional.empty());
    when(budget.reserve(true)).thenReturn(true);
    when(pricing.getQuote("AAPL")).thenReturn(quote(now));
    var cache = new QuoteCache(pricing, Duration.ofMinutes(10), Clock.fixed(now, ZoneOffset.UTC), store, budget, null);
    assertNotNull(cache.search("AAPL"));
    verify(budget).reserve(true);
    assertThrows(com.avengers.endgame.integration.pricing.exception.PricingRateLimitException.class, () -> cache.display("MSFT"));
    verify(pricing, never()).getQuote("MSFT");
 }
 private static QuoteResponse quote(Instant at) {
    return new QuoteResponse("AAPL", BigDecimal.TEN, BigDecimal.TEN, BigDecimal.TEN, null,
        "USD", null, null, null, at, "CLOSED", false, "test");
 }
 // Order freeze: a provider call stuck on one symbol must not make every other quote wait behind it.
 @Test void aSlowProviderCallDoesNotBlockOtherSymbols() throws Exception {
    var pricing = mock(PricingApiClient.class);
    var entered = new java.util.concurrent.CountDownLatch(1);
    var release = new java.util.concurrent.CountDownLatch(1);
    var aapl = new QuoteResponse("AAPL", BigDecimal.TEN, BigDecimal.TEN, BigDecimal.TEN, null,
        "USD", null, null, null, Instant.now(), "OPEN", false, "test");
    var msft = new QuoteResponse("MSFT", BigDecimal.ONE, BigDecimal.ONE, BigDecimal.ONE, null,
        "USD", null, null, null, Instant.now(), "OPEN", false, "test");
    when(pricing.getQuote("AAPL")).thenAnswer(call -> { entered.countDown(); release.await(); return aapl; });
    when(pricing.getQuote("MSFT")).thenReturn(msft);
    var cache = new QuoteCache(pricing, Duration.ofMinutes(1));
    var stuck = new Thread(() -> cache.fresh("AAPL"));
    stuck.start();
    try {
        assertTrue(entered.await(2, java.util.concurrent.TimeUnit.SECONDS));
        assertSame(msft, assertTimeoutPreemptively(Duration.ofSeconds(2), () -> cache.display("MSFT")));
    } finally {
        release.countDown();
        stuck.join(2000);
    }
 }
}
