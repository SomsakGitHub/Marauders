# ADR-006: Retry policy for `GET /v1/feed` only

**Status:** Accepted  
**Date:** 2026-10-09  
**Scope:** `FeedAPIClient` transient failures

## Context

Mobile networks drop connections briefly. `GET /v1/feed` is **idempotent** — safe to repeat. `POST /v1/videos` is large, slow, and not idempotent without server keys, so automatic upload retry is out of scope.

## Decision

- **`FeedAPIClient.fetchFeed`** retries up to **3 attempts** (initial + 2 retries).
- **Backoff:** 0.5s → 1s → 2s cap (`productionRetryDelay`).
- **Retry when:** `FeedAPIError.serverError` for **502, 503, 504**, or transient `URLError` (timeout, connection lost, offline, DNS, etc.).
- **Never retry:** `invalidLimit`, `invalidResponse`, other 4xx/5xx, decode/HTTPS validation failures.
- Logic in `FeedAPIRetryPolicy`; upload client unchanged.

## Consequences

- **Pros:** Better feed load on flaky LTE without ViewModel changes.
- **Cons:** Up to ~3.5s extra wait before surfacing hard failure; must not duplicate with user-initiated reload spam (ViewModel generation still drops stale responses).

## References

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — HTTP API contract
- `Data/API/FeedAPIClient.swift`, `FeedAPIRetryPolicy.swift`
