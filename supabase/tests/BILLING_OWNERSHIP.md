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

Transfer changes no usage counters, refinement credits, or reservations.
The PostgreSQL regression transfers an account with 75 charged operations and
one remaining refinement: the destination receives 75 operations and that one
refinement. The previous owner cannot reserve or reclaim access with sync.
An operation reserved before a transfer may finish against the same allowance;
this task does not change OpenAI reservation accounting.

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
`deno fmt --check` targets only the four changed TypeScript files.

Real PostgreSQL tests: initialize a disposable local PostgreSQL cluster, start
it listening only on 127.0.0.1 on an unused port, set PG_BIN to its bin directory
and PGPORT to that port, then run `python supabase/tests/billing_ownership_test.py`.
The runner creates a uniquely named test database, builds minimal auth/role
fixtures, applies the actual unapplied migration, executes concurrent real SQL
connections, and removes its database. It never accepts a hosted DSN.
Use a disposable cluster because the minimal roles are cluster-wide fixtures.
Stop and remove the temporary cluster afterward. No Docker/Supabase stack or
hosted Supabase is exercised, and Swift/XCTest cannot run on Windows.

Recorded results: Deno 123 passed, 0 failed, 17 external integration tests ignored; PostgreSQL 21 passed, 0 failed. TypeScript checks and git diff --check passed. Changed TypeScript formatting: 3 files pass; revenuecat-webhook/index.ts retains five pre-existing formatting hunks (also present at HEAD), as requested. No new formatting differences remain. The isolated PostgreSQL server was stopped and its temporary cluster removed.
