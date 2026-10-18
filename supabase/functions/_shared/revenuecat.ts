export interface TrustedSubscriptionState {
  active: boolean;
  originalTransactionId: string | null;
  productId: string | null;
  periodStartedAt: string | null;
  expiresAt: string | null;
  store: string;
  environment: string;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}

function optionalDate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

/** Fetches subscription truth directly from RevenueCat. No client-supplied
 * entitlement, product, expiry, or transaction fields are accepted. */
export async function fetchRevenueCatSubscription(
  appUserId: string,
): Promise<TrustedSubscriptionState> {
  const apiKey = requiredEnv("REVENUECAT_API_KEY");
  const entitlementId = requiredEnv("REVENUECAT_ENTITLEMENT_ID");
  const expectedProducts = new Set(
    (Deno.env.get("REVENUECAT_PRODUCT_IDS") ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
  if (expectedProducts.size === 0) {
    throw new Error("REVENUECAT_PRODUCT_IDS is not configured");
  }
  const base = Deno.env.get("REVENUECAT_API_BASE_URL")?.trim() ||
    "https://api.revenuecat.com/v1";

  const response = await fetch(
    `${base}/subscribers/${encodeURIComponent(appUserId)}`,
    {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        Accept: "application/json",
      },
    },
  );
  if (!response.ok) {
    throw new Error(`RevenueCat subscriber lookup failed (${response.status})`);
  }

  const payload = await response.json() as Record<string, unknown>;
  const subscriber = payload.subscriber as Record<string, unknown> | undefined;
  const entitlements = subscriber?.entitlements as
    | Record<string, Record<string, unknown>>
    | undefined;
  const entitlement = entitlements?.[entitlementId];

  if (!entitlement) {
    return {
      active: false,
      originalTransactionId: null,
      productId: null,
      periodStartedAt: null,
      expiresAt: null,
      store: Deno.env.get("REVENUECAT_EXPECTED_STORE") ?? "APP_STORE",
      environment: Deno.env.get("REVENUECAT_EXPECTED_ENVIRONMENT") ??
        "PRODUCTION",
    };
  }

  const productId = typeof entitlement.product_identifier === "string"
    ? entitlement.product_identifier
    : null;
  if (!productId || !expectedProducts.has(productId)) {
    throw new Error("RevenueCat returned an unexpected product");
  }

  const subscriptions = subscriber?.subscriptions as
    | Record<string, Record<string, unknown>>
    | undefined;
  const subscription = productId ? subscriptions?.[productId] : undefined;
  // RevenueCat is trusted, but only Apple's stable original transaction ID is
  // accepted as a billing-account key. Do not substitute app user IDs or
  // mutable transaction IDs.
  const originalTransactionId =
    typeof subscription?.original_transaction_id === "string"
      ? subscription.original_transaction_id
      : typeof entitlement.original_transaction_id === "string"
      ? entitlement.original_transaction_id
      : null;
  const expiresAt = optionalDate(entitlement.expires_date);
  // Greenshot v1 supports auto-renewable subscriptions only. A missing
  // expiration must never be interpreted as lifetime access.
  const active = expiresAt !== null &&
    new Date(expiresAt).getTime() > Date.now();

  return {
    active,
    originalTransactionId,
    productId,
    periodStartedAt: optionalDate(
      subscription?.purchase_date ?? entitlement.purchase_date,
    ),
    expiresAt,
    store: typeof subscription?.store === "string"
      ? subscription.store
      : (Deno.env.get("REVENUECAT_EXPECTED_STORE") ?? "APP_STORE"),
    environment: typeof subscription?.environment === "string"
      ? subscription.environment
      : (Deno.env.get("REVENUECAT_EXPECTED_ENVIRONMENT") ?? "PRODUCTION"),
  };
}

/** Events that mean "entitled to Plus right now". CANCELLATION is
 * deliberately absent-but-entitled: it only means auto-renew was turned
 * off, and RevenueCat sends EXPIRATION when access actually ends.
 * BILLING_ISSUE keeps access during the grace period. */
export const GRANTS_PLUS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "NON_RENEWING_PURCHASE",
  "SUBSCRIPTION_EXTENDED",
  "BILLING_ISSUE",
  "CANCELLATION",
]);

/** Events that end access. */
export const REVOKES_PLUS = new Set(["EXPIRATION", "SUBSCRIPTION_PAUSED", "REFUND"]);

/** A new or renewed period resets the monthly allowance. */
export const RESETS_PERIOD = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "NON_RENEWING_PURCHASE",
]);

export const OWNERSHIP_EVENTS = new Set(["TRANSFER", "SUBSCRIBER_ALIAS"]);

export function classifyRevenueCatEvent(
  type: string,
): "grant" | "revoke" | "ownership" | "ignore" {
  if (REVOKES_PLUS.has(type)) return "revoke";
  if (GRANTS_PLUS.has(type)) return "grant";
  if (OWNERSHIP_EVENTS.has(type)) return "ownership";
  return "ignore";
}

export function revenueCatEventResetsPeriod(type: string): boolean {
  return RESETS_PERIOD.has(type);
}

/**
 * Whether Postgres may be asked to zero the monthly allowance.
 * SERVER_SYNC and grant events without a trusted period start must never
 * reset usage. A missing timestamp is not replaced with now().
 */
export function periodResetRequested(
  eventType: string,
  trustedPeriodStartedAt: string | null,
): boolean {
  return revenueCatEventResetsPeriod(eventType) &&
    trustedPeriodStartedAt !== null;
}

export interface UsagePeriodState {
  analysesUsed: number;
  refinementsRemaining: number;
  periodStartedAt: string;
}

/**
 * Mirrors apply_revenuecat_event's user_usage ON CONFLICT rules so the
 * quota-reset policy can be unit-tested without a live database.
 */
export function applyTrustedUsagePeriod(args: {
  eventType: string;
  isActive: boolean;
  trustedPeriodStartedAt: string | null;
  eventAt: string;
  existing: UsagePeriodState | null;
}): UsagePeriodState | null {
  if (!args.isActive) return args.existing;
  if (!args.existing) {
    return {
      analysesUsed: 0,
      refinementsRemaining: 0,
      periodStartedAt: args.trustedPeriodStartedAt ?? args.eventAt,
    };
  }
  const incoming = args.trustedPeriodStartedAt;
  const reset = periodResetRequested(args.eventType, incoming) &&
    incoming !== null &&
    Date.parse(incoming) > Date.parse(args.existing.periodStartedAt);
  return {
    analysesUsed: reset ? 0 : args.existing.analysesUsed,
    refinementsRemaining: reset ? 0 : args.existing.refinementsRemaining,
    periodStartedAt: reset && incoming
      ? incoming
      : args.existing.periodStartedAt,
  };
}

export function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  const length = Math.max(a.length, b.length);
  let difference = a.length ^ b.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return difference === 0;
}
