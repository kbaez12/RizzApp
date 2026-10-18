# Durable AI accounting: local implementation

## Failure and delivery gate

Previously generate returned HTTP 200 and replies on a commit RPC error; analyze
also returned HTTP 200 and analysis on that error. A reserved row could then
expire and refund delivered output. Missing data could throw into broad catch
blocks, which attempted release even after a potentially successful commit.

Both authenticated handlers now use deliverReservedOperation. Only a fresh,
nonempty reservation ID may invoke the model. Subscription denials, duplicate
IDs, unknown outcomes, and reservation failures never invoke it. Reserve
transport/errors return 503 with same-request-ID guidance; they do not attempt
to release an unknown reservation.

After model success, at most two commit calls use exactly the original
reservation ID. Success requires a response with no RPC error and exactly
outcome=committed. Null/missing data, unexpected outcomes, errors accompanying
committed data, and thrown transport failures are not confirmation.

If neither mutation confirms commitment, a separate server-only
get_user_reservation_status RPC reads the authoritative PostgreSQL row. It
returns only status and usage, does not mutate, and is denied to public, anon,
and authenticated roles. A successful committed read is sufficient because
committed is terminal under the existing release/expiration rules. A reserved
read is NOT proof that a delayed commit cannot still complete. Missing,
released, reserved, malformed, or failed reads cannot authorize delivery.

Confirmed commitment returns the output still available in that handler's
memory. Otherwise HTTP 503 ACCOUNTING_UNCONFIRMED contains no AI output, and
no release is attempted. There is no second reservation, model call, or charge
to recover an acknowledgment. Duplicate request IDs return 409 without model,
commit, or release calls. The messages explain that output cannot be replayed
and advise refreshing usage before deliberately starting a new request.

## Refunds and monthly compatibility

Only a model/generation failure before any commit attempt enters the refund
path. Release is conditional on reserved status in SQL, idempotent, and uses
the existing original-window guards. Logs report refunded only after a
successful released result; failed/ambiguous releases are marked refund_pending.
No upstream exception text or generated content is logged.

Uncommitted reservations remain eligible for existing lazy expiration cleanup
when a later distinct accepted reservation invokes it. A duplicate alone or a
usage read does not trigger that cleanup; this is not an immediate refund
guarantee. Committed rows never expire to free output. Old-window cleanup never
credits the current window. No counters, subscription ownership rules,
200-operation monthly allowance, two included refinements, renewal logic,
entitlement checks, or transfer behavior were changed.

## Lost output, reconciliation, and credits

A lost commit acknowledgment is recoverable while output remains in memory if
either repeat commit or the separate status read succeeds. This prevents an
unnecessary operation loss in the recoverable case, without double charging.

There remains a charge-without-output scenario: PostgreSQL commits, every
confirmation fails (or the worker dies), and the output disappears with the
worker. Even after confirmed commitment, the worker/client connection may fail
before the client receives or displays HTTP 200. A subsequent duplicate cannot
replay the output because no conversation, screenshot, prompt, or reply is
persisted. An included refinement can likewise be consumed without delivery.
The implementation does not claim guaranteed delivery or guaranteed refunds.

Investigated reconciliation: the authoritative metadata read safely resolves
accounting state, but cannot establish client receipt. Committed status proves
a charge, not delivery or non-delivery. Blindly releasing/crediting all committed
duplicates, timeouts, missing client receipts, or old log entries could refund
successfully delivered output and reintroduce the original flaw. Therefore no
automatic committed-operation credit is added. Reservation IDs in operational
logs allow trusted investigation without recording AI content. An explicit
operator goodwill credit would be a separate authorized policy decision; this
patch neither grants such credits nor weakens committed-row immutability.

A future metadata-only reconciliation design could atomically mark a request
as abandoned BEFORE allowing any response delivery and issue an idempotent
credit scoped to its original allowance window. All response paths would need
to respect that terminal transition; delayed commits and concurrent workers
must be fenced out. This can cover a live worker deliberately abandoning output,
but still cannot prove non-delivery after a worker crash or broken client
connection. A client acknowledgment alone is insufficient because it can be
lost or withheld. These are architectural/policy decisions, not guarantees
provided by this targeted patch.

## Validation

Focused mocked RPC tests exercise the actual generate/analyze handlers with
injected model results, not a separate implementation of their decisions.
Real PostgreSQL tests apply the actual historical quota migration followed by
the unapplied mandatory-subscription migration in a disposable local cluster.

Commands (Deno 2.9.6; PostgreSQL 17):

- deno test --config supabase/functions/deno.json --allow-env supabase/functions/_shared/durable_accounting_test.ts
- deno test --config supabase/functions/deno.json --allow-env supabase/functions
- deno check --config supabase/functions/deno.json supabase/functions/_shared/*.ts supabase/functions/generate/index.ts supabase/functions/analyze/index.ts supabase/functions/usage/index.ts supabase/functions/subscription-sync/index.ts supabase/functions/revenuecat-webhook/index.ts
- deno fmt --check supabase/functions/_shared/idempotency.ts supabase/functions/_shared/durable_accounting_test.ts supabase/functions/generate/index.ts supabase/functions/analyze/index.ts
- PG_BIN=<PostgreSQL 17 bin> PGPORT=55439 python supabase/tests/billing_ownership_test.py
- git diff --check

External integration flags stay disabled. Hosted Supabase/PostgREST, live OpenAI,
RevenueCat, and Swift/iOS builds are not exercised. The new RPC must exist before
an eventual deployed function can use the fallback read. No hosted migration,
deployment, configuration change, commit, or push is authorized or performed.
Recorded results on 2026-10-18:

- Focused handler tests: 55 passed, 0 failed.
- Full Deno backend: 174 passed, 0 failed, 17 external integration tests ignored.
- PostgreSQL: 54 passed, 0 failed in 42.714 seconds (21 existing ownership,
  22 existing monthly allowance/accounting, 11 new durability tests).
- TypeScript: all shared modules and all five Edge entrypoints passed.
- Formatting: all four changed TypeScript files passed.
- git diff --check: passed.

Dependency-dependent Deno runs used the existing cache outside the restricted
sandbox. The first sandbox PostgreSQL initialization was blocked by filesystem
permissions; the successful run used a separate disposable local cluster outside
the sandbox. Its database and stopped cluster were removed. No hosted services
were contacted by tests. The pre-existing untracked __pycache__ was preserved.

Ready for a controlled local commit, with the delivery/credit limitations above
explicitly retained. Deployment readiness still requires separately authorized
hosted integration verification and the documented migration/function sequencing.
