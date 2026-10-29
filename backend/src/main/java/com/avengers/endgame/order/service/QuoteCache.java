package com.avengers.endgame.order.service;

import com.avengers.endgame.integration.pricing.client.PricingApiClient;
import com.avengers.endgame.integration.pricing.dto.QuoteResponse;
import com.avengers.endgame.integration.pricing.exception.PricingApiException;
import com.avengers.endgame.integration.pricing.exception.PricingRateLimitException;
import org.springframework.stereotype.Component;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.context.ApplicationEventPublisher;
import java.time.*;
import java.util.LinkedHashMap;
import java.util.Map;

/** One shared provider observation per symbol/TTL, including searches and trades. */
@Component
public class QuoteCache {
    private static final Duration FAILURE_COOLDOWN = Duration.ofSeconds(30);
    private record Entry(QuoteResponse quote, Instant fetchedAt) {}
    private final PricingApiClient pricing;
    private final Duration ttl;
    private final Clock clock;
    private final SavedQuoteRepository saved;
    private final PricingRequestBudget budget;
    private final ApplicationEventPublisher events;
    private final Map<String, Entry> quotes = new LinkedHashMap<>();
    private final Map<String, Instant> retryAfter = new LinkedHashMap<>();
    private final Object[] stripes = java.util.stream.IntStream.range(0, 64).mapToObj(i -> new Object()).toArray();
    private static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(QuoteCache.class);

    @Autowired
    public QuoteCache(PricingApiClient pricing, @Value("${pricing.api.display-cache-ttl:PT15M}") Duration ttl,
            ApplicationEventPublisher events, ObjectProvider<SavedQuoteRepository> saved,
            ObjectProvider<PricingRequestBudget> budget) {
        this(pricing, ttl, Clock.systemUTC(), saved.getIfAvailable(), budget.getIfAvailable(), events);
    }
    public QuoteCache(PricingApiClient pricing, Duration ttl) { this(pricing, ttl, Clock.systemUTC()); }
    public QuoteCache(PricingApiClient pricing, Duration ttl, Clock clock) { this(pricing, ttl, clock, null, null, null); }
    public QuoteCache(PricingApiClient pricing, Duration ttl, ApplicationEventPublisher events) {
        this(pricing, ttl, Clock.systemUTC(), null, null, events);
    }
    public QuoteCache(PricingApiClient pricing, Duration ttl, Clock clock,
            SavedQuoteRepository saved, PricingRequestBudget budget, ApplicationEventPublisher events) {
        if (ttl.isNegative()) throw new IllegalArgumentException("Quote cache TTL cannot be negative");
        this.pricing = pricing; this.ttl = ttl; this.clock = clock;
        this.saved = saved; this.budget = budget; this.events = events;
    }
    public QuoteResponse display(String symbol) { return get(symbol, false); }
    // Retained method name for callers: execution now shares the same latest available quote.
    public QuoteResponse fresh(String symbol) { return get(symbol, false); }
    public QuoteResponse search(String symbol) { return get(symbol, true); }

    private QuoteResponse get(String symbol, boolean interactive) {
        if (symbol == null || !symbol.trim().toUpperCase(java.util.Locale.ROOT)
                .matches("(?:[A-Z0-9][A-Z0-9.\\^-]{0,19}|X:[A-Z0-9]+-USD)"))
            throw new PricingApiException("Invalid stock ticker");
        String key = symbol.trim().toUpperCase(java.util.Locale.ROOT);
        QuoteResponse fetched = null;
        synchronized (stripes[Math.floorMod(key.hashCode(), stripes.length)]) {
            Entry entry;
            synchronized (quotes) { entry = quotes.get(key); }
            if (entry == null && saved != null) {
                var stored = saved.find(key);
                if (stored.isPresent() && usable(key, stored.get().quote())) {
                    entry = new Entry(stored.get().quote(), stored.get().fetchedAt());
                    remember(key, entry);
                }
            }
            Instant now = clock.instant();
            if (entry != null && now.isBefore(entry.fetchedAt().plus(ttl))) return entry.quote();
            Instant retry;
            synchronized (retryAfter) { retry = retryAfter.get(key); }
            if (retry != null && now.isBefore(retry)) {
                if (entry != null) return fallback(entry.quote());
                throw new PricingApiException("Pricing is temporarily unavailable. Please try again shortly.");
            }
            if (budget != null && !budget.reserve(interactive)) {
                if (entry != null) return fallback(entry.quote());
                throw new PricingRateLimitException(null);
            }
            try {
                fetched = pricing.getQuote(key);
                if (usable(key, fetched)) {
                    if (entry != null && entry.quote().asOf().isAfter(fetched.asOf())) fetched = entry.quote();
                    if (saved != null) saved.save(key, fetched, now);
                    remember(key, new Entry(fetched, now));
                    synchronized (retryAfter) { retryAfter.remove(key); }
                } else {
                    backoff(key, now.plus(FAILURE_COOLDOWN));
                    if (entry != null) return fallback(entry.quote());
                    // Existing validation reports malformed quotes; do not save them.
                }
            } catch (PricingApiException failure) {
                Instant until = failure instanceof PricingRateLimitException limited ? limited.retryAt() : now.plus(FAILURE_COOLDOWN);
                if (failure instanceof PricingRateLimitException && budget != null) budget.pauseUntil(until);
                backoff(key, until);
                if (entry != null) return fallback(entry.quote());
                throw failure;
            }
        }
        // Publish outside stripe and map locks. Never re-publish a saved fallback as a new observation.
        if (events != null && fetched != null && usable(key, fetched)) {
            try { events.publishEvent(fetched); }
            catch (RuntimeException failure) { log.warn("Reporting mark could not be saved ({})", failure.getClass().getSimpleName()); }
        }
        return fetched;
    }
    private void remember(String key, Entry entry) {
        if (ttl.isZero()) return; // Zero TTL deliberately disables memory caching in lifecycle tests.
        synchronized (quotes) {
            if (quotes.size() >= 512 && !quotes.containsKey(key)) quotes.remove(quotes.keySet().iterator().next());
            quotes.put(key, entry);
        }
    }
    private void backoff(String key, Instant until) {
        if (ttl.isZero()) return;
        synchronized (retryAfter) {
            if (retryAfter.size() >= 512 && !retryAfter.containsKey(key)) retryAfter.remove(retryAfter.keySet().iterator().next());
            retryAfter.put(key, until);
        }
    }
    private boolean usable(String key, QuoteResponse quote) {
        return quote != null && key.equalsIgnoreCase(quote.symbol()) && "USD".equalsIgnoreCase(quote.currency())
                && quote.price() != null && quote.price().signum() > 0
                && quote.bid() != null && quote.bid().signum() > 0 && quote.ask() != null && quote.ask().signum() > 0
                && quote.asOf() != null && !quote.asOf().isAfter(clock.instant().plusSeconds(5));
    }
    private QuoteResponse fallback(QuoteResponse q) {
        return new QuoteResponse(q.symbol(), q.price(), q.bid(), q.ask(), q.spreadBps(), q.currency(),
                q.change(), q.changePercent(), q.previousClose(), q.asOf(), q.marketState(), true, "saved-cache");
    }
}
