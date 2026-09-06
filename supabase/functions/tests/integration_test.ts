// Integration tests against a RUNNING local Supabase stack.
//
// Prerequisites:
//   supabase start
//   supabase functions serve --env-file supabase/functions/.env
//
// Run:
//   INTEGRATION=true SUPABASE_URL=http://127.0.0.1:54321 \
//   PUBLISHABLE_KEY=<local publishable/anon key> \
//   deno test --allow-net --allow-env supabase/functions/tests/integration_test.ts
//
// Uses fresh random installation IDs per test, so it is rerunnable without
// a db reset. Skipped entirely unless INTEGRATION=true.

import { assertEquals } from "jsr:@std/assert";

const RUN = Deno.env.get("INTEGRATION") === "true";
const BASE = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const KEY = Deno.env.get("PUBLISHABLE_KEY") ?? "";

// Matches supabase/seed.sql fixtures.
const EXHAUSTED_INSTALLATION = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const PLUS_INSTALLATION = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

interface CallOptions {
  installationId?: string;
  requestId?: string;
  refinement?: string | null;
  apikey?: string;
  scenario?: string;
}

function generateBody(options: CallOptions) {
  return {
    input: { kind: "text", text: "them: hey lol\nme: hey" },
    goal: "flirty",
    refinement: options.refinement ?? null,
    previous_responses: null,
    request_id: options.requestId ?? crypto.randomUUID(),
  };
}

async function callGenerate(options: CallOptions): Promise<Response> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    apikey: options.apikey ?? KEY,
    "x-installation-id": options.installationId ?? crypto.randomUUID(),
    // Quota/idempotency tests use canned replies so they never spend
    // OpenAI calls. Response quality is judged with quality_check.ts.
    "x-debug-scenario": options.scenario ?? "canned",
  };
  return await fetch(`${BASE}/functions/v1/generate`, {
    method: "POST",
    headers,
    body: JSON.stringify(generateBody(options)),
  });
}

async function callUsage(installationId: string, apikey = KEY): Promise<Response> {
  return await fetch(`${BASE}/functions/v1/usage`, {
    headers: { apikey, "x-installation-id": installationId },
  });
}

Deno.test({ name: "fresh installation: usage 5/5, 0 refinements", ignore: !RUN }, async () => {
  const response = await callUsage(crypto.randomUUID());
  assertEquals(response.status, 200);
  const usage = await response.json();
  assertEquals(usage.remaining, 5);
  assertEquals(usage.limit, 5);
  assertEquals(usage.tier, "free");
  assertEquals(usage.refinements_remaining, 0);
});

Deno.test({ name: "generation charges analysis and grants refinements", ignore: !RUN }, async () => {
  const installation = crypto.randomUUID();
  const response = await callGenerate({ installationId: installation });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.responses.length, 3);
  assertEquals(body.usage.remaining, 4);
  assertEquals(body.usage.refinements_remaining, 2);
});

Deno.test({ name: "refinement sequence 2 → 1 → 0 → charges analysis", ignore: !RUN }, async () => {
  const installation = crypto.randomUUID();
  await (await callGenerate({ installationId: installation })).body?.cancel();

  const r1 = await (await callGenerate({ installationId: installation, refinement: "shorter" })).json();
  assertEquals(r1.usage.remaining, 4);
  assertEquals(r1.usage.refinements_remaining, 1);

  const r2 = await (await callGenerate({ installationId: installation, refinement: "bolder" })).json();
  assertEquals(r2.usage.refinements_remaining, 0);

  // Third refinement: free budget gone → consumes a full analysis and
  // starts a fresh refinement allowance.
  const r3 = await (await callGenerate({ installationId: installation, refinement: "less_cringe" })).json();
  assertEquals(r3.usage.remaining, 3);
  assertEquals(r3.usage.refinements_remaining, 2);
});

Deno.test({ name: "duplicate request_id does not double-charge", ignore: !RUN }, async () => {
  const installation = crypto.randomUUID();
  const requestId = crypto.randomUUID();
  const first = await (await callGenerate({ installationId: installation, requestId })).json();
  const second = await (await callGenerate({ installationId: installation, requestId })).json();
  assertEquals(first.usage.remaining, 4);
  assertEquals(second.usage.remaining, 4, "retry must not charge again");
});

Deno.test({ name: "exhausted installation gets 402 with usage", ignore: !RUN }, async () => {
  const response = await callGenerate({ installationId: EXHAUSTED_INSTALLATION });
  assertEquals(response.status, 402);
  const body = await response.json();
  assertEquals(body.error.code, "QUOTA_EXCEEDED");
  assertEquals(body.usage.remaining, 0);
});

Deno.test({ name: "simulated failure after reserve refunds quota", ignore: !RUN }, async () => {
  const installation = crypto.randomUUID();
  const failed = await callGenerate({
    installationId: installation,
    scenario: "fail_after_reserve",
  });
  assertEquals(failed.status, 500);
  await failed.body?.cancel();

  const usage = await (await callUsage(installation)).json();
  assertEquals(usage.remaining, 5, "failed generation must be refunded");
  assertEquals(usage.refinements_remaining, 0);
});

Deno.test({ name: "free-refinement refund restores exact count", ignore: !RUN }, async () => {
  const installation = crypto.randomUUID();
  await (await callGenerate({ installationId: installation })).body?.cancel();
  await (await callGenerate({ installationId: installation, refinement: "shorter" })).body?.cancel();
  // 1 refinement left; fail a refinement → must restore exactly 1, not 2.
  const failed = await callGenerate({
    installationId: installation,
    refinement: "bolder",
    scenario: "fail_after_reserve",
  });
  assertEquals(failed.status, 500);
  await failed.body?.cancel();

  const usage = await (await callUsage(installation)).json();
  assertEquals(usage.remaining, 4);
  assertEquals(usage.refinements_remaining, 1);
});

Deno.test({ name: "concurrent requests cannot overspend the last analysis", ignore: !RUN }, async () => {
  const installation = crypto.randomUUID();
  // Burn 4 of 5.
  for (let i = 0; i < 4; i++) {
    await (await callGenerate({ installationId: installation })).body?.cancel();
  }
  const [a, b] = await Promise.all([
    callGenerate({ installationId: installation }),
    callGenerate({ installationId: installation }),
  ]);
  const statuses = [a.status, b.status].sort();
  await a.body?.cancel();
  await b.body?.cancel();
  assertEquals(statuses, [200, 402], "exactly one may win the last analysis");

  const usage = await (await callUsage(installation)).json();
  assertEquals(usage.remaining, 0);
});

Deno.test({ name: "plus test installation has configured allowance", ignore: !RUN }, async () => {
  const usage = await (await callUsage(PLUS_INSTALLATION)).json();
  assertEquals(usage.tier, "plus");
  assertEquals(usage.limit, 150);
});

Deno.test({ name: "invalid apikey is rejected", ignore: !RUN }, async () => {
  const response = await callUsage(crypto.randomUUID(), "sb_publishable_totally_fake");
  assertEquals(response.status, 401);
  await response.body?.cancel();
});

Deno.test({ name: "missing installation id rejected", ignore: !RUN }, async () => {
  const response = await fetch(`${BASE}/functions/v1/usage`, {
    headers: { apikey: KEY },
  });
  assertEquals(response.status, 400);
  await response.body?.cancel();
});

Deno.test({ name: "invalid request_id rejected", ignore: !RUN }, async () => {
  const response = await fetch(`${BASE}/functions/v1/generate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: KEY,
      "x-installation-id": crypto.randomUUID(),
    },
    body: JSON.stringify({ ...generateBody({}), request_id: "not-a-uuid" }),
  });
  assertEquals(response.status, 400);
  await response.body?.cancel();
});
