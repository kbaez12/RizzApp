import { assertEquals, assertRejects } from "jsr:@std/assert";
import {
  applyTrustedUsagePeriod,
  classifyRevenueCatEvent,
  fetchRevenueCatSubscription,
  periodResetRequested,
  revenueCatEventResetsPeriod,
} from "./revenuecat.ts";

const USER_ID = "123e4567-e89b-42d3-a456-426614174000";
const PRODUCT_ID = "greenshot_monthly";
const FUTURE = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
const PAST = new Date(Date.now() - 60 * 1000).toISOString();

function subscriberPayload(overrides: {
  entitlements?: Record<string, Record<string, unknown>>;
  subscriptions?: Record<string, Record<string, unknown>>;
} = {}) {
  return {
    subscriber: {
      entitlements: overrides.entitlements ?? {
        plus: {
          product_identifier: PRODUCT_ID,
          expires_date: FUTURE,
          purchase_date: new Date().toISOString(),
        },
      },
      subscriptions: overrides.subscriptions ?? {
        [PRODUCT_ID]: {
          store_transaction_id: "1000000123456789",
          expires_date: FUTURE,
          purchase_date: new Date().toISOString(),
          store: "app_store",
          is_sandbox: true,
          period_type: "normal",
        },
      },
    },
  };
}

async function withRevenueCatEnv<T>(run: () => Promise<T>): Promise<T> {
  const original = {
    key: Deno.env.get("REVENUECAT_API_KEY"),
    entitlement: Deno.env.get("REVENUECAT_ENTITLEMENT_ID"),
    products: Deno.env.get("REVENUECAT_PRODUCT_IDS"),
    store: Deno.env.get("REVENUECAT_EXPECTED_STORE"),
    environment: Deno.env.get("REVENUECAT_EXPECTED_ENVIRONMENT"),
    base: Deno.env.get("REVENUECAT_API_BASE_URL"),
  };
  const originalFetch = globalThis.fetch;
  try {
    Deno.env.set("REVENUECAT_API_KEY", "test-only");
    Deno.env.set("REVENUECAT_ENTITLEMENT_ID", "plus");
    Deno.env.set("REVENUECAT_PRODUCT_IDS", `${PRODUCT_ID},greenshot_yearly`);
    Deno.env.set("REVENUECAT_EXPECTED_STORE", "APP_STORE");
    Deno.env.set("REVENUECAT_EXPECTED_ENVIRONMENT", "SANDBOX");
    Deno.env.set("REVENUECAT_API_BASE_URL", "https://revenuecat.test/v1");
    return await run();
  } finally {
    globalThis.fetch = originalFetch;
    restoreEnvironment("REVENUECAT_API_KEY", original.key);
    restoreEnvironment("REVENUECAT_ENTITLEMENT_ID", original.entitlement);
    restoreEnvironment("REVENUECAT_PRODUCT_IDS", original.products);
    restoreEnvironment("REVENUECAT_EXPECTED_STORE", original.store);
    restoreEnvironment("REVENUECAT_EXPECTED_ENVIRONMENT", original.environment);
    restoreEnvironment("REVENUECAT_API_BASE_URL", original.base);
  }
}

function restoreEnvironment(name: string, value: string | undefined) {
  if (value === undefined) {
    Deno.env.delete(name);
  } else {
    Deno.env.set(name, value);
  }
}

Deno.test("webhook event classification grants, revokes, and ignores correctly", () => {
  assertEquals(classifyRevenueCatEvent("INITIAL_PURCHASE"), "grant");
  assertEquals(classifyRevenueCatEvent("CANCELLATION"), "grant");
  assertEquals(classifyRevenueCatEvent("BILLING_ISSUE"), "grant");
  assertEquals(classifyRevenueCatEvent("EXPIRATION"), "revoke");
  assertEquals(classifyRevenueCatEvent("REFUND"), "revoke");
  assertEquals(classifyRevenueCatEvent("TRANSFER"), "ownership");
  assertEquals(classifyRevenueCatEvent("TEST"), "ignore");
  assertEquals(revenueCatEventResetsPeriod("INITIAL_PURCHASE"), true);
  assertEquals(revenueCatEventResetsPeriod("CANCELLATION"), false);
  assertEquals(revenueCatEventResetsPeriod("EXPIRATION"), false);
});

Deno.test("active plus entitlement is derived only from RevenueCat", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = (input) => {
      assertEquals(
        String(input),
        `https://revenuecat.test/v1/subscribers/${USER_ID}`,
      );
      return Promise.resolve(
        new Response(JSON.stringify(subscriberPayload()), { status: 200 }),
      );
    };

    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, true);
    assertEquals(state.productId, PRODUCT_ID);
    assertEquals(state.originalTransactionId, null);
    assertEquals(state.store, "APP_STORE");
    assertEquals(state.environment, "SANDBOX");
  });
});

Deno.test("missing entitlement is inactive and does not invent lifetime access", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = () =>
      Promise.resolve(
        new Response(JSON.stringify(subscriberPayload({ entitlements: {} })), {
          status: 200,
        }),
      );

    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, false);
    assertEquals(state.productId, null);
    assertEquals(state.originalTransactionId, null);
    assertEquals(state.store, "");
    assertEquals(state.environment, "");
  });
});

Deno.test("expired or missing expiration is never treated as active", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = () =>
      Promise.resolve(
        new Response(
          JSON.stringify(subscriberPayload({
            entitlements: {
              plus: {
                product_identifier: PRODUCT_ID,
                expires_date: PAST,
              },
            },
          })),
          { status: 200 },
        ),
      );
    const expired = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(expired.active, false);

    globalThis.fetch = () =>
      Promise.resolve(
        new Response(
          JSON.stringify(subscriberPayload({
            entitlements: {
              plus: { product_identifier: PRODUCT_ID },
            },
          })),
          { status: 200 },
        ),
      );
    const lifetime = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(lifetime.active, false);
  });
});

Deno.test("unexpected product is rejected", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = () =>
      Promise.resolve(
        new Response(
          JSON.stringify(subscriberPayload({
            entitlements: {
              plus: {
                product_identifier: "not-a-configured-product",
                expires_date: FUTURE,
              },
            },
          })),
          { status: 200 },
        ),
      );

    await assertRejects(
      () => fetchRevenueCatSubscription(USER_ID),
      Error,
      "unexpected product",
    );
  });
});

Deno.test("RevenueCat lookup failures fail closed", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = () =>
      Promise.resolve(new Response("no", { status: 500 }));
    await assertRejects(
      () => fetchRevenueCatSubscription(USER_ID),
      Error,
      "subscriber lookup failed",
    );
  });
});

Deno.test("missing purchase dates stay null instead of inventing now()", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = () =>
      Promise.resolve(
        new Response(
          JSON.stringify(subscriberPayload({
            entitlements: {
              plus: {
                product_identifier: PRODUCT_ID,
                expires_date: FUTURE,
              },
            },
            subscriptions: {
              [PRODUCT_ID]: {
                store: "app_store",
                is_sandbox: true,
                period_type: "normal",
                expires_date: FUTURE,
              },
            },
          })),
          { status: 200 },
        ),
      );
    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, true);
    assertEquals(state.periodStartedAt, null);
    assertEquals(
      periodResetRequested("SERVER_SYNC", state.periodStartedAt),
      false,
    );
  });
});

function mockSubscriber(payload: unknown) {
  globalThis.fetch = () =>
    Promise.resolve(new Response(JSON.stringify(payload), { status: 200 }));
}

Deno.test("production monthly subscription uses is_sandbox false", async () => {
  await withRevenueCatEnv(async () => {
    Deno.env.set("REVENUECAT_EXPECTED_ENVIRONMENT", "PRODUCTION");
    const payload = subscriberPayload();
    payload.subscriber.subscriptions[PRODUCT_ID].is_sandbox = false;
    mockSubscriber(payload);
    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, true);
    assertEquals(state.environment, "PRODUCTION");
  });
});

Deno.test("allowlisted yearly subscription is active", async () => {
  await withRevenueCatEnv(async () => {
    const payload = subscriberPayload();
    const subscription = payload.subscriber.subscriptions[PRODUCT_ID];
    payload.subscriber.entitlements.plus.product_identifier =
      "greenshot_yearly";
    payload.subscriber.subscriptions = { greenshot_yearly: subscription };
    mockSubscriber(payload);
    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, true);
    assertEquals(state.productId, "greenshot_yearly");
  });
});

const INVALID_ACTIVE_SUBSCRIPTIONS: {
  name: string;
  field: string;
  value: unknown;
  error: string;
}[] = [
  ...[undefined, null, "true", "false", 0, 1, {}, []].map((value) => ({
    name: `invalid is_sandbox ${JSON.stringify(value)}`,
    field: "is_sandbox",
    value,
    error: "environment",
  })),
  ...[
    undefined,
    null,
    "",
    123,
    "play_store",
    "stripe",
    "unknown",
    "promotional",
  ]
    .map((value) => ({
      name: `invalid store ${JSON.stringify(value)}`,
      field: "store",
      value,
      error: "store",
    })),
  ...[
    undefined,
    null,
    "",
    1,
    "trial",
    "intro",
    "promotional",
    "prepaid",
    "NORMAL",
    "unknown",
  ]
    .map((value) => ({
      name: `ineligible period_type ${JSON.stringify(value)}`,
      field: "period_type",
      value,
      error: "period type",
    })),
  {
    name: "refunded subscription",
    field: "refunded_at",
    value: PAST,
    error: "refunded",
  },
];

for (const { name, field, value, error } of INVALID_ACTIVE_SUBSCRIPTIONS) {
  Deno.test(`${name} cannot grant paid access`, async () => {
    await withRevenueCatEnv(async () => {
      const payload = subscriberPayload();
      payload.subscriber.subscriptions[PRODUCT_ID][field] = value;
      mockSubscriber(payload);
      await assertRejects(
        () => fetchRevenueCatSubscription(USER_ID),
        Error,
        error,
      );
    });
  });
}

for (const expectedEnvironment of ["PRODUCTION", "SANDBOX"]) {
  Deno.test(`opposite sandbox flag is rejected for ${expectedEnvironment}`, async () => {
    await withRevenueCatEnv(async () => {
      Deno.env.set("REVENUECAT_EXPECTED_ENVIRONMENT", expectedEnvironment);
      const payload = subscriberPayload();
      payload.subscriber.subscriptions[PRODUCT_ID].is_sandbox =
        expectedEnvironment === "PRODUCTION";
      mockSubscriber(payload);
      await assertRejects(
        () => fetchRevenueCatSubscription(USER_ID),
        Error,
        "environment",
      );
    });
  });
}

Deno.test("legacy environment cannot override a missing sandbox flag", async () => {
  await withRevenueCatEnv(async () => {
    const payload = subscriberPayload();
    delete payload.subscriber.subscriptions[PRODUCT_ID].is_sandbox;
    payload.subscriber.subscriptions[PRODUCT_ID].environment = "SANDBOX";
    mockSubscriber(payload);
    await assertRejects(
      () => fetchRevenueCatSubscription(USER_ID),
      Error,
      "environment",
    );
  });
});

for (
  const subscriptions of [undefined, null, [], {}, { unrelated: {} }, {
    [PRODUCT_ID]: null,
  }]
) {
  Deno.test(`missing exact subscription ${JSON.stringify(subscriptions)} fails closed`, async () => {
    await withRevenueCatEnv(async () => {
      mockSubscriber({
        subscriber: { ...subscriberPayload().subscriber, subscriptions },
      });
      await assertRejects(
        () => fetchRevenueCatSubscription(USER_ID),
        Error,
        "matching subscription",
      );
    });
  });
}

for (const field of ["entitlements", "subscriptions"] as const) {
  for (const expiration of [undefined, null, "invalid", PAST]) {
    Deno.test(`${field} expiration ${JSON.stringify(expiration)} cannot grant access`, async () => {
      await withRevenueCatEnv(async () => {
        const payload = subscriberPayload();
        const record = field === "entitlements"
          ? payload.subscriber.entitlements.plus
          : payload.subscriber.subscriptions[PRODUCT_ID];
        record.expires_date = expiration;
        mockSubscriber(payload);
        assertEquals(
          (await fetchRevenueCatSubscription(USER_ID)).active,
          false,
        );
      });
    });
  }
}

Deno.test("earlier verified expiration limits access", async () => {
  await withRevenueCatEnv(async () => {
    const payload = subscriberPayload();
    const earlier = new Date(Date.now() + 60_000).toISOString();
    payload.subscriber.subscriptions[PRODUCT_ID].expires_date = earlier;
    mockSubscriber(payload);
    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, true);
    assertEquals(state.expiresAt, earlier);
  });
});

Deno.test("cancellation preserves a normal paid period until expiration", async () => {
  await withRevenueCatEnv(async () => {
    const payload = subscriberPayload();
    payload.subscriber.subscriptions[PRODUCT_ID].unsubscribe_detected_at = PAST;
    mockSubscriber(payload);
    assertEquals((await fetchRevenueCatSubscription(USER_ID)).active, true);
  });
});

Deno.test("undocumented original transaction fields are never used as identity", async () => {
  await withRevenueCatEnv(async () => {
    const payload = subscriberPayload();
    payload.subscriber.subscriptions[PRODUCT_ID].original_transaction_id =
      "unverified";
    payload.subscriber.entitlements.plus.original_transaction_id =
      "also-unverified";
    mockSubscriber(payload);
    const state = await fetchRevenueCatSubscription(USER_ID);
    assertEquals(state.active, true);
    assertEquals(state.originalTransactionId, null);
  });
});

for (
  const payload of [
    null,
    [],
    "invalid",
    {},
    { subscriber: null },
    { subscriber: [] },
    { subscriber: {} },
    { subscriber: { entitlements: [] } },
    { subscriber: { entitlements: { plus: null } } },
    { subscriber: { entitlements: { plus: [] } } },
  ]
) {
  Deno.test(`malformed response ${JSON.stringify(payload)} fails closed`, async () => {
    await withRevenueCatEnv(async () => {
      mockSubscriber(payload);
      await assertRejects(
        () => fetchRevenueCatSubscription(USER_ID),
        Error,
        "malformed",
      );
    });
  });
}

Deno.test("malformed JSON fails closed", async () => {
  await withRevenueCatEnv(async () => {
    globalThis.fetch = () => Promise.resolve(new Response("{"));
    await assertRejects(
      () => fetchRevenueCatSubscription(USER_ID),
      SyntaxError,
    );
  });
});

for (
  const [name, value] of [
    ["REVENUECAT_EXPECTED_STORE", undefined],
    ["REVENUECAT_EXPECTED_ENVIRONMENT", undefined],
    ["REVENUECAT_EXPECTED_STORE", "PROMOTIONAL"],
    ["REVENUECAT_EXPECTED_ENVIRONMENT", "unknown"],
  ]
) {
  Deno.test(`invalid source configuration ${name} ${value} fails closed`, async () => {
    await withRevenueCatEnv(async () => {
      if (value === undefined) Deno.env.delete(name!);
      else Deno.env.set(name!, value);
      mockSubscriber(subscriberPayload());
      await assertRejects(() => fetchRevenueCatSubscription(USER_ID), Error);
    });
  });
}

const PERIOD_START = "2026-10-01T00:00:00.000Z";
const LATER_PERIOD = "2026-11-01T00:00:00.000Z";
const EVENT_NOW = "2026-10-18T19:00:00.000Z";
const USED = {
  analysesUsed: 41,
  refinementsRemaining: 1,
  periodStartedAt: PERIOD_START,
};

Deno.test("first verified active subscription opens a zeroed allowance", () => {
  const created = applyTrustedUsagePeriod({
    eventType: "INITIAL_PURCHASE",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: EVENT_NOW,
    existing: null,
  });
  assertEquals(created, {
    analysesUsed: 0,
    refinementsRemaining: 0,
    periodStartedAt: PERIOD_START,
  });
});

Deno.test("repeated SERVER_SYNC during the same period preserves usage", () => {
  const first = applyTrustedUsagePeriod({
    eventType: "SERVER_SYNC",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  const second = applyTrustedUsagePeriod({
    eventType: "SERVER_SYNC",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: "2026-10-18T19:05:00.000Z",
    existing: first,
  });
  assertEquals(periodResetRequested("SERVER_SYNC", PERIOD_START), false);
  assertEquals(second, USED);
});

Deno.test("missing period start never synthesizes a new billing month", () => {
  const afterSync = applyTrustedUsagePeriod({
    eventType: "SERVER_SYNC",
    isActive: true,
    trustedPeriodStartedAt: null,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  assertEquals(afterSync, USED);
  assertEquals(periodResetRequested("RENEWAL", null), false);
  const afterRenewalWithoutDate = applyTrustedUsagePeriod({
    eventType: "RENEWAL",
    isActive: true,
    trustedPeriodStartedAt: null,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  assertEquals(afterRenewalWithoutDate, USED);
});

Deno.test("older billing-period event does not reset usage", () => {
  const after = applyTrustedUsagePeriod({
    eventType: "RENEWAL",
    isActive: true,
    trustedPeriodStartedAt: "2026-09-01T00:00:00.000Z",
    eventAt: EVENT_NOW,
    existing: USED,
  });
  assertEquals(after, USED);
});

Deno.test("duplicate lifecycle event with the same period preserves usage", () => {
  const after = applyTrustedUsagePeriod({
    eventType: "INITIAL_PURCHASE",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  assertEquals(after, USED);
});

Deno.test("legitimate renewal with a strictly newer trusted period resets usage", () => {
  const after = applyTrustedUsagePeriod({
    eventType: "RENEWAL",
    isActive: true,
    trustedPeriodStartedAt: LATER_PERIOD,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  assertEquals(after, {
    analysesUsed: 0,
    refinementsRemaining: 0,
    periodStartedAt: LATER_PERIOD,
  });
});

Deno.test("expired or revoked subscriptions do not reopen or reset usage", () => {
  const after = applyTrustedUsagePeriod({
    eventType: "EXPIRATION",
    isActive: false,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  assertEquals(after, USED);
  assertEquals(
    applyTrustedUsagePeriod({
      eventType: "SERVER_SYNC",
      isActive: false,
      trustedPeriodStartedAt: PERIOD_START,
      eventAt: EVENT_NOW,
      existing: USED,
    }),
    USED,
  );
});

Deno.test("concurrent SERVER_SYNC applications preserve the same usage", () => {
  const left = applyTrustedUsagePeriod({
    eventType: "SERVER_SYNC",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  const right = applyTrustedUsagePeriod({
    eventType: "SERVER_SYNC",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: "2026-10-18T19:00:01.000Z",
    existing: USED,
  });
  assertEquals(left, USED);
  assertEquals(right, USED);
  assertEquals(
    applyTrustedUsagePeriod({
      eventType: "SERVER_SYNC",
      isActive: true,
      trustedPeriodStartedAt: PERIOD_START,
      eventAt: "2026-10-18T19:00:02.000Z",
      existing: left,
    }),
    USED,
  );
});

Deno.test("pending billing identity then verified transaction keeps spent quota", () => {
  const afterPendingSync = applyTrustedUsagePeriod({
    eventType: "SERVER_SYNC",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: EVENT_NOW,
    existing: USED,
  });
  const afterAppleIdentity = applyTrustedUsagePeriod({
    eventType: "INITIAL_PURCHASE",
    isActive: true,
    trustedPeriodStartedAt: PERIOD_START,
    eventAt: "2026-10-18T19:10:00.000Z",
    existing: afterPendingSync,
  });
  assertEquals(afterAppleIdentity, USED);
});
