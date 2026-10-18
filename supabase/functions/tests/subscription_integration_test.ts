// Integration tests against a running local stack. Requires two local auth
// users and the same RevenueCat fixture values used by the function env.
//
// SUBSCRIPTION_INTEGRATION=true USER_JWT=... USER_ID=... \
// UNSUBSCRIBED_USER_JWT=... PUBLISHABLE_KEY=... \
// deno test --allow-net --allow-env this-file.ts

import { assertEquals } from "jsr:@std/assert";

const RUN = Deno.env.get("SUBSCRIPTION_INTEGRATION") === "true";
const BASE = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const KEY = Deno.env.get("PUBLISHABLE_KEY") ?? "";
const JWT = Deno.env.get("USER_JWT") ?? "";
const USER_ID = Deno.env.get("USER_ID") ?? "";
const UNSUBSCRIBED_JWT = Deno.env.get("UNSUBSCRIBED_USER_JWT") ?? "";
const WEBHOOK_SECRET = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ??
  "local-dev-webhook-secret";
const APP_ID = Deno.env.get("REVENUECAT_APP_ID") ?? "app_REPLACE_ME";
const PRODUCT_ID = (Deno.env.get("REVENUECAT_PRODUCT_IDS") ?? "")
  .split(",")
  .map((value) => value.trim())
  .find(Boolean) ?? "REPLACE_WITH_TEST_PRODUCT_ID";

function userHeaders(jwt: string) {
  return {
    apikey: KEY,
    Authorization: `Bearer ${jwt}`,
    "Content-Type": "application/json",
  };
}

async function webhook(event: Record<string, unknown>) {
  return await fetch(`${BASE}/functions/v1/revenuecat-webhook`, {
    method: "POST",
    headers: {
      Authorization: WEBHOOK_SECRET,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ event }),
  });
}

function entitlementEvent(overrides: Record<string, unknown> = {}) {
  const now = Date.now();
  return {
    id: crypto.randomUUID(),
    type: "INITIAL_PURCHASE",
    event_timestamp_ms: now,
    purchased_at_ms: now,
    expiration_at_ms: now + 30 * 24 * 60 * 60 * 1000,
    app_user_id: USER_ID,
    original_app_user_id: USER_ID,
    aliases: [USER_ID],
    original_transaction_id: `test-${crypto.randomUUID()}`,
    app_id: APP_ID,
    entitlement_ids: ["plus"],
    product_id: PRODUCT_ID,
    environment: "SANDBOX",
    store: "APP_STORE",
    ...overrides,
  };
}

Deno.test({
  name: "invalid JWT is a distinct 401",
  ignore: !RUN,
}, async () => {
  const response = await fetch(`${BASE}/functions/v1/usage`, {
    headers: userHeaders("invalid.jwt.value"),
  });
  assertEquals(response.status, 401);
});

Deno.test({
  name: "authenticated user without entitlement gets mandatory 402",
  ignore: !RUN,
}, async () => {
  const response = await fetch(`${BASE}/functions/v1/generate`, {
    method: "POST",
    headers: {
      ...userHeaders(UNSUBSCRIBED_JWT),
      "x-debug-scenario": "canned",
    },
    body: JSON.stringify({
      input: { kind: "text", text: "them: hey\nme: hi" },
      goal: "flirty",
      refinement: null,
      previous_responses: null,
      request_id: crypto.randomUUID(),
    }),
  });
  assertEquals(response.status, 402);
  assertEquals((await response.json()).error.code, "SUBSCRIPTION_REQUIRED");
});

Deno.test({
  name: "webhook duplicate and older event cannot revoke current access",
  ignore: !RUN,
}, async () => {
  const grant = entitlementEvent();
  const first = await webhook(grant);
  assertEquals(first.status, 200);
  assertEquals((await first.json()).outcome, "applied");

  const duplicate = await webhook(grant);
  assertEquals((await duplicate.json()).outcome, "duplicate");

  const stale = await webhook(entitlementEvent({
    id: crypto.randomUUID(),
    type: "EXPIRATION",
    event_timestamp_ms: Number(grant.event_timestamp_ms) - 1000,
    original_transaction_id: grant.original_transaction_id,
  }));
  assertEquals((await stale.json()).outcome, "stale");

  const usage = await fetch(`${BASE}/functions/v1/usage`, {
    headers: userHeaders(JWT),
  });
  assertEquals(usage.status, 200);
  const body = await usage.json();
  assertEquals(body.subscribed, true);
  assertEquals(body.limit, 200);
  assertEquals(body.remaining, 200);
});
