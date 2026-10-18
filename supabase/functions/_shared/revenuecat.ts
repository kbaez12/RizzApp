import { isUserId } from "./auth.ts";

/** Aliases are historical identifiers, not an ordered owner preference list.
 * Transfers must use destination identities exclusively. */
export function revenueCatOwnerCandidates(
  type: string,
  appUserId: string,
  aliases: string[],
  transferredTo: string[],
): string[] {
  const candidates = type === "TRANSFER"
    ? transferredTo
    : isUserId(appUserId)
    ? [appUserId]
    : aliases;
  return [...new Set(candidates.filter(isUserId))];
}

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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
  const expectedStore = requiredEnv("REVENUECAT_EXPECTED_STORE").toUpperCase();
  const expectedEnvironment = requiredEnv("REVENUECAT_EXPECTED_ENVIRONMENT")
    .toUpperCase();
  if (
    expectedStore !== "APP_STORE" ||
    !["SANDBOX", "PRODUCTION"].includes(expectedEnvironment)
  ) {
    throw new Error(
      "RevenueCat subscription source configuration is unsupported",
    );
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

  const payload: unknown = await response.json();
  if (
    !isRecord(payload) || !isRecord(payload.subscriber) ||
    !isRecord(payload.subscriber.entitlements)
  ) {
    throw new Error("RevenueCat returned a malformed subscriber response");
  }
  const subscriber = payload.subscriber;
  const entitlements = subscriber.entitlements as Record<string, unknown>;
  const entitlement = Object.hasOwn(entitlements, entitlementId)
    ? entitlements[entitlementId]
    : undefined;

  if (entitlement === undefined) {
    return {
      active: false,
      originalTransactionId: null,
      productId: null,
      periodStartedAt: null,
      expiresAt: null,
      // No subscription source is known. These values must not be invented
      // from validation configuration, even for an inactive customer.
      store: "",
      environment: "",
    };
  }
  if (!isRecord(entitlement)) {
    throw new Error("RevenueCat returned a malformed entitlement");
  }

  const productId = typeof entitlement.product_identifier === "string"
    ? entitlement.product_identifier
    : null;
  if (!productId || !expectedProducts.has(productId)) {
    throw new Error("RevenueCat returned an unexpected product");
  }

  const subscriptions = subscriber.subscriptions;
  if (
    !isRecord(subscriptions) || !Object.hasOwn(subscriptions, productId) ||
    !isRecord(subscriptions[productId])
  ) {
    throw new Error("RevenueCat returned no matching subscription record");
  }
  const subscription = subscriptions[productId] as Record<string, unknown>;
  const entitlementExpiresAt = optionalDate(entitlement.expires_date);
  const subscriptionExpiresAt = optionalDate(subscription.expires_date);
  // Both records must confirm a paid period. Use the earlier expiration so
  // inconsistent data can never extend access beyond either source record.
  const expiresAt = entitlementExpiresAt && subscriptionExpiresAt
    ? new Date(Math.min(
      Date.parse(entitlementExpiresAt),
      Date.parse(subscriptionExpiresAt),
    )).toISOString()
    : null;
  // Greenshot v1 supports auto-renewable subscriptions only. A missing
  // expiration must never be interpreted as lifetime access.
  const active = expiresAt !== null &&
    new Date(expiresAt).getTime() > Date.now();
  const store = typeof subscription.store === "string"
    ? subscription.store.toUpperCase()
    : "";
  const environment = typeof subscription.is_sandbox === "boolean"
    ? (subscription.is_sandbox ? "SANDBOX" : "PRODUCTION")
    : "";
  if (active) {
    if (!environment || environment !== expectedEnvironment) {
      throw new Error(
        "RevenueCat returned an unexpected or missing environment",
      );
    }
    if (store !== "APP_STORE" || store !== expectedStore) {
      throw new Error("RevenueCat returned an unexpected or missing store");
    }
    // API v1 uses normal/trial/intro. Introductory pricing is not sufficient
    // evidence of a paid period for Greenshot's current products.
    if (subscription.period_type !== "normal") {
      throw new Error("RevenueCat returned an ineligible paid period type");
    }
    if (subscription.refunded_at != null) {
      throw new Error("RevenueCat returned a refunded subscription");
    }
  }

  return {
    active,
    // REST API v1 documents store_transaction_id, not Apple's stable original
    // transaction ID. Neither it nor any user identifier can replace that ID.
    originalTransactionId: null,
    productId,
    periodStartedAt: optionalDate(
      subscription?.purchase_date ?? entitlement.purchase_date,
    ),
    expiresAt,
    store,
    environment,
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
export const REVOKES_PLUS = new Set([
  "EXPIRATION",
  "SUBSCRIPTION_PAUSED",
  "REFUND",
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

/** Event types and purchase timestamps never authorize an early quota reset.
 * Calendar allowance advancement is enforced exclusively in PostgreSQL using
 * its clock and the billing account's immutable verified purchase anchor.
 * Retained for the existing RPC wire contract; p_reset_period is ignored. */
export function revenueCatEventResetsPeriod(_type: string): boolean {
  return false;
}

export function periodResetRequested(
  _eventType: string,
  _trustedPeriodStartedAt: string | null,
): boolean {
  return false;
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
