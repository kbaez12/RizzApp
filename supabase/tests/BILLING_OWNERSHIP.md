# Subscription ownership: local implementation notes

The unapplied `20261018000000_mandatory_subscriptions.sql` migration is the
only migration changed. No hosted database, secrets, functions, RevenueCat
settings, or Apple products were changed.

## Trust and allowance

Only a secret-authenticated RevenueCat lifecycle event containing Apple's
original transaction ID can create a billing account. The unique transaction
constraint ensures one usage row per purchase. REST v1 entitlement lookup
cannot create accounts or change ownership. No client transaction is accepted.

Lifecycle owners use the event's canonical UUID, or exactly one UUID alias
when the canonical ID is anonymous. Transfers use exactly one destination UUID
and require a server-side subscriber lookup. Auth users must exist.

Aliases retain historical account associations. A transfer resolves the source
aliases exclusively and proceeds only when they identify exactly one purchase.
Destination aliases cannot choose the source. Different legitimate purchases
are never merged. When the destination owns another account, that account is
detached with its usage and aliases preserved; the transferred account becomes
the destination's selected account.

Ingestion is serialized with a transaction advisory lock. Ownership changes
also acquire the account row locks used by reservations. Entitlement refresh
and ownership ordering are separate; sync cannot hide a late transfer. Older
transfers cannot revert ownership; distinct ownership events at the same
timestamp fail closed because opaque event IDs cannot establish their order.

Transfer preserves usage counters, refinement credits, and reservations within
the same allowance window. A legitimately due monthly boundary is handled by
the same server-clock policy as usage reads and reservations.
The PostgreSQL regression transfers an account with 75 charged operations and
one remaining refinement: the destination receives 125 operations and that one
refinement. The previous owner cannot reserve or reclaim access with sync.
An operation reserved before a transfer may finish against the same allowance;
OpenAI execution and same-window accounting remain unchanged; cross-window
refunds are scoped to the original allowance period as described below.

## Pending verification and recovery

Sync returns HTTP 200 with `subscribed: false`, zero spendable counters,
`verification_status: pending_verification`, and `retry_after_seconds: 5`.
The existing Swift client reads the raw usage shape, revokes local premium,
and displays its existing "purchase is still being verified" message. Purchase,
restore, and refresh can retry. No Swift adjustment is required.

Unresolved transfers persist as pending ledger entries and return HTTP 503 so
RevenueCat retries. Known ambiguous source accounts are detached to block
spending. A transfer arriving before its purchase creates a barrier: the late
purchase records its stable account and entitlement without unlocking the old
owner, then the same transfer can succeed on redelivery. Processed event IDs
are idempotent. REST failures grant nothing and return retryable errors.

## Deployment blockers and operational dependencies

RevenueCat documents `original_transaction_id` on subscription lifecycle events,
while TRANSFER identifies source/destination aliases and may omit store and
environment. Missing TRANSFER source fields are constrained by the existing
account and the validated destination subscriber response; explicit mismatches
are rejected.

https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
https://www.revenuecat.com/docs/integrations/webhooks/sample-events

Before deployment, independently verify that this app's RevenueCat setup emits
and delivers the required lifecycle/TRANSFER events and supports the existing
Customer Authentication identity binding. No hosted configuration was verified.

REST v1 cannot recover a stable original transaction for a purchase whose
lifecycle webhook was never recorded. A trusted lifecycle redelivery is needed.
If multiple historical purchases match a transfer's source aliases, the payload
cannot identify which purchase should become the single selected account.
Such cases, alias-only identity changes, and equal-time ownership conflicts
remain locked. They require trusted transaction-level ownership reconciliation
or an explicitly authorized operator procedure backed by verified RevenueCat
purchase history. No automatic or client-supplied workaround is implemented.
RevenueCat retries are finite; a still-pending event may need trusted redelivery
after its missing lifecycle event is available. This is not deployment-ready
until these operational recovery dependencies are resolved.

## Validation and reproduction

Deno 2.9.6: `deno test --config supabase/functions/deno.json --allow-env
supabase/functions` with INTEGRATION, LEGACY_INSTALLATION_INTEGRATION, and
SUBSCRIPTION_INTEGRATION unset. The external HTTP integration suites are skipped.
TypeScript checks cover all shared modules and all five Edge entrypoints.
`deno fmt --check` targets only the six changed TypeScript files.

Real PostgreSQL tests: initialize a disposable local PostgreSQL cluster, start
it listening only on 127.0.0.1 on an unused port, set PG_BIN to its bin directory
and PGPORT to that port, then run `python supabase/tests/billing_ownership_test.py`.
The runner creates a uniquely named test database, builds minimal auth/role
fixtures, applies the actual unapplied migration, executes concurrent real SQL
connections, and removes its database. It never accepts a hosted DSN.
Use a disposable cluster because the minimal roles are cluster-wide fixtures.
Stop and remove the temporary cluster afterward. No Docker/Supabase stack or
hosted Supabase is exercised, and Swift/XCTest cannot run on Windows.

## Final launch allowance and monthly advancement

Launch policy: $5.99 USD per month, 200 charged AI operations per monthly
allowance window, and two included refinements per eligible charged operation.
Annual subscribers receive the same monthly allowance; annual pricing remains
unfinalized. These are product decisions, not changes to Apple/RevenueCat prices.
The live purchase interface continues to use localized StoreKit/RevenueCat prices.
Mock offerings display a price placeholder instead of invented example prices.

Each stable purchase account receives a fixed allowance_anchor_at from its first
usable trusted paid lifecycle start. Missing/future starts grant no usage and
recover through a later verified lifecycle event. Renewal, restoration, sync,
transfer, and product changes do not move an established anchor.

PostgreSQL computes calendar-month anniversaries in UTC from the original
anchor. Month-end clipping retains the original day for subsequent months
(Jan 31 -> Feb 28/29 -> Mar 31); windows use inclusive starts and exclusive ends.
User usage reads, reservations, and accepted reconciliation advance a due window
using only the database clock and a still-active, unexpired verified entitlement.
Annual subscriptions require no annual renewal webhook at each monthly boundary.
Renewal/product-change timestamps and the retained p_reset_period wire argument
cannot reset counters early. Missed windows do not accumulate allowances.

On advancement, charged usage and previous-window refinement credits are zeroed.
A charged operation in the new window grants two included refinements. Every
reservation records its allowance period: releasing an older-window reservation
cannot refund operations or refinements into the new window. Same-window refund
and idempotency behavior is retained; a pre-boundary operation may finish.

The unapplied migration also supersedes the historical legacy Plus usage_config
value with 200. Previously applied migrations remain unchanged. Historical SQL
and image dimensions are the only remaining 150/300 occurrences; no active
subscription allowance uses those values.

Calendar arithmetic follows PostgreSQL's month intervals, with explicit UTC
conversion to avoid session timezone/DST dependence:
https://www.postgresql.org/docs/17/functions-datetime.html

The regression runner applies the actual historical quota migration followed
by the corrected unapplied migration in its disposable database. Deterministic
calendar tests cover every annual monthly window and exact month-end boundaries.
Transactional rollover tests seed preceding-window persisted usage while keeping
the server clock real; no application RPC accepts a caller-supplied reset clock.
Hosted Supabase/RevenueCat integration and iOS compilation remain unvalidated.

Recorded local results: PostgreSQL 43 passed, 0 failed (21 ownership regressions plus 22 allowance/accounting tests). Deno 119 passed, 0 failed, 17 external integration tests skipped. The obsolete TypeScript SQL-mirror quota tests were replaced by real PostgreSQL coverage and five assertions that events cannot request resets. TypeScript checks and git diff --check passed. Changed TypeScript formatting: five files pass; subscription_test.ts retains two pre-existing formatting hunks. The disposable PostgreSQL database and cluster were removed. Swift/XCTest and hosted integration were not run.

## Pre-commit test inventory audit against 3097d0ca

The Deno total changes by four, rather than four individually deleted tests:
123 - 9 obsolete TypeScript SQL-mirror tests + 5 event-reset guard tests = 119.
The nine replaced tests and their actual PostgreSQL coverage are:

- "first verified active subscription opens a zeroed allowance": test_new_purchase.
- "repeated SERVER_SYNC during the same period preserves usage": test_same_identity_restore and test_syncs_and_transfer_keep_fixed_anchor.
- "missing period start never synthesizes a new billing month": test_missing_or_future_paid_start_is_locked and test_missing_anchor_recovers_with_verified_lifecycle.
- "older billing-period event does not reset usage": test_renewal_and_plan_change_cannot_reset_early (older, same, newer and future dates).
- "duplicate lifecycle event with the same period preserves usage": test_concurrent_duplicate_webhook and test_renewal_and_plan_change_cannot_reset_early.
- "legitimate renewal with a strictly newer trusted period resets usage": intentionally superseded by test_exact_boundary_and_no_early_reset, test_monthly_refreshes_when_read_or_reserved and test_annual_refreshes_without_annual_renewal_webhook. A newer event purchase date alone must no longer authorize an early reset.
- "expired or revoked subscriptions do not reopen or reset usage": test_expired_or_revoked_entitlement_cannot_refresh_overdue_month (both states).
- "concurrent SERVER_SYNC applications preserve the same usage": test_syncs_and_transfer_keep_fixed_anchor now uses concurrent syncs; test_concurrent_month_refresh_and_spending verifies transactional advancement.
- "pending billing identity then verified transaction keeps spent quota": superseded by test_sync_before_webhook, test_missing_stable_transaction, test_different_identity_restore and test_75_consumed_and_refinements_preserved. Provisional spendable accounts are forbidden, so the old mirror's pending-account model is obsolete.

The five new Deno tests reject event-driven reset requests for INITIAL_PURCHASE,
RENEWAL, PRODUCT_CHANGE, SERVER_SYNC, and TRANSFER (including missing dates).
No integration test was newly skipped. All 21 original SQL ownership tests remain,
with 22 allowance/accounting tests added. RevenueCat parser/security test bodies
before the removed mirror section remain unchanged except for the intentional
assertion that INITIAL_PURCHASE cannot directly request a reset. No accidentally
removed security test was found; replacement SQL cases were strengthened for
revocation, repeated/older dates, and concurrent synchronization during review.
