// POST /functions/v1/revenuecat-webhook
//
// Server-to-server entitlement sync. RevenueCat is the source of truth for
// subscription state; the iOS client can never set its own tier.
//
// Auth: RevenueCat sends a fixed Authorization header value that we
// configure in its dashboard and compare against REVENUECAT_WEBHOOK_SECRET.
// `auth: "none"` disables Supabase key checking for this endpoint because
// the caller is RevenueCat, not our app — the shared secret is the gate.
//
// Logging: event type, mapped tier, installation id, status. No customer
// PII, no receipts, no conversation data (there is none here).

import { withSupabase } from "npm:@supabase/server@1";
import { errorJson, json } from "../_shared/responses.ts";
import { isUserId } from "../_shared/auth.ts";
import {
  classifyRevenueCatEvent,
  constantTimeEqual,
  fetchRevenueCatSubscription,
  OWNERSHIP_EVENTS,
  periodResetRequested,
} from "../_shared/revenuecat.ts";

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function dateFromMs(value: unknown): string | null {
  const number = Number(value);
  return Number.isFinite(number) && number > 0
    ? new Date(number).toISOString()
    : null;
}

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    if (req.method !== "POST") {
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use POST.");
    }

    const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET")?.trim();
    const supplied = req.headers.get("Authorization") ?? "";
    if (!expected || !constantTimeEqual(supplied, expected)) {
      console.log(JSON.stringify({ fn: "revenuecat-webhook", status: 401 }));
      return errorJson(401, "UNAUTHORIZED", "Invalid webhook credentials.");
    }
    // deno-lint-ignore no-explicit-any
    const admin = ctx.supabaseAdmin as any;

    let payload: { event?: Record<string, unknown> };
    try {
      payload = await req.json();
    } catch {
      return errorJson(400, "INVALID_JSON", "Body must be valid JSON.");
    }

    const event = payload.event ?? {};
    const eventId = String(event.id ?? "");
    const type = String(event.type ?? "");
    const appUserId = String(event.app_user_id ?? "");
    const originalAppUserId = String(event.original_app_user_id ?? "");
    const aliases = [
      appUserId,
      originalAppUserId,
      ...strings(event.aliases),
      ...strings(event.transferred_from),
      ...strings(event.transferred_to),
    ].filter((value, index, all) => value && all.indexOf(value) === index);
    const eventAt = dateFromMs(event.event_timestamp_ms);
    const originalTransactionId = String(
      event.original_transaction_id ?? "",
    ).trim();

    const expectedAppId = Deno.env.get("REVENUECAT_APP_ID")?.trim();
    const expectedEntitlement = Deno.env.get("REVENUECAT_ENTITLEMENT_ID")?.trim();
    const expectedEnvironment =
      Deno.env.get("REVENUECAT_EXPECTED_ENVIRONMENT")?.trim();
    const expectedStore = Deno.env.get("REVENUECAT_EXPECTED_STORE")?.trim();
    const environment = String(event.environment ?? "");
    const store = String(event.store ?? "");
    const entitlementIds = strings(event.entitlement_ids);

    const log = (status: number, note: string, tier?: string) =>
      console.log(JSON.stringify({
        fn: "revenuecat-webhook",
        status,
        type,
        tier: tier ?? null,
        eventId,
        appUserId,
        note,
      }));
    const ledgerWithoutApplying = async (
      status: "ignored" | "rejected",
      reason: string,
    ) => {
      if (!eventId || !eventAt) return;
      await admin.from("revenuecat_webhook_events").upsert({
        event_id: eventId,
        event_type: type || "UNKNOWN",
        event_at: eventAt,
        original_transaction_id: originalTransactionId || null,
        app_user_id: appUserId || null,
        status,
        reason,
      }, { onConflict: "event_id", ignoreDuplicates: true });
    };

    if (
      !expectedAppId || !expectedEntitlement || !expectedEnvironment ||
      !expectedStore
    ) {
      log(503, "validation_config_missing");
      return errorJson(503, "MISCONFIGURED", "Webhook validation is not configured.");
    }
    if (!eventId || !eventAt) {
      return errorJson(400, "INVALID_EVENT", "Event id and timestamp are required.");
    }
    if (
      event.app_id !== expectedAppId || environment !== expectedEnvironment ||
      store !== expectedStore
    ) {
      await ledgerWithoutApplying("rejected", "unexpected_source");
      log(200, "unexpected_source");
      return json(200, { ok: true, ignored: true });
    }
    if (
      !entitlementIds.includes(expectedEntitlement) &&
      !OWNERSHIP_EVENTS.has(type)
    ) {
      await ledgerWithoutApplying("ignored", "unexpected_entitlement");
      log(200, "unexpected_entitlement");
      return json(200, { ok: true, ignored: true });
    }
    const expectedProducts = new Set(
      (Deno.env.get("REVENUECAT_PRODUCT_IDS") ?? "")
        .split(",")
        .map((value) => value.trim())
        .filter(Boolean),
    );
    if (expectedProducts.size === 0) {
      log(503, "product_validation_config_missing");
      return errorJson(503, "MISCONFIGURED", "Webhook products are not configured.");
    }
    let productId = String(event.product_id ?? "").trim();
    if (
      !OWNERSHIP_EVENTS.has(type) &&
      (expectedProducts.size === 0 || !expectedProducts.has(productId))
    ) {
      await ledgerWithoutApplying("ignored", "unexpected_product");
      log(200, "unexpected_product");
      return json(200, { ok: true, ignored: true });
    }

    const classification = classifyRevenueCatEvent(type);
    let active: boolean;
    if (classification === "revoke") {
      active = false;
    } else if (classification === "grant") {
      active = true;
    } else if (classification === "ownership") {
      active = Number(event.expiration_at_ms ?? 0) > Date.now();
    } else {
      await ledgerWithoutApplying("ignored", "unsupported_event_type");
      log(200, "ignored_event");
      return json(200, { ok: true, ignored: true });
    }

    let expiresAt = dateFromMs(event.expiration_at_ms);
    let periodStartedAt = dateFromMs(
      event.purchased_at_ms ?? event.period_started_at_ms,
    );
    if (active && !OWNERSHIP_EVENTS.has(type) &&
        (!originalTransactionId || !expiresAt)) {
      await ledgerWithoutApplying("rejected", "missing_subscription_identity");
      return errorJson(
        400,
        "INVALID_EVENT",
        "Active subscriptions require an original transaction and expiration.",
      );
    }

    // Prefer the transfer destination as owner, then the canonical/current
    // app user id. A UUID is accepted only if it exists in auth.users.
    const ownerCandidates = [
      ...strings(event.transferred_to),
      appUserId,
      originalAppUserId,
      ...aliases,
    ].filter(isUserId);
    let userId: string | null = null;
    for (const candidate of ownerCandidates) {
      const { data, error } = await admin.auth.admin.getUserById(
        candidate,
      );
      if (!error && data.user) {
        userId = candidate;
        break;
      }
    }

    // Lifecycle payloads identify the stable Apple transaction, while a
    // server-to-server subscriber lookup supplies current entitlement truth.
    // This makes delayed/out-of-order webhooks converge instead of blindly
    // applying the last payload delivered.
    if (userId && !OWNERSHIP_EVENTS.has(type)) {
      try {
        const current = await fetchRevenueCatSubscription(userId);
        active = current.active;
        productId = current.productId ?? productId;
        expiresAt = current.expiresAt;
        periodStartedAt = current.periodStartedAt ?? periodStartedAt;
      } catch {
        return errorJson(
          503,
          "RECONCILIATION_UNAVAILABLE",
          "Could not reconcile subscription state.",
        );
      }
    }
    if (!OWNERSHIP_EVENTS.has(type) && !expectedProducts.has(productId)) {
      await ledgerWithoutApplying("rejected", "reconciled_unexpected_product");
      return errorJson(
        400,
        "INVALID_EVENT",
        "Reconciled subscription product is not allowed.",
      );
    }

    if (active && !originalTransactionId && aliases.length === 0) {
      return errorJson(
        400,
        "UNMAPPABLE_EVENT",
        "A stable transaction or known alias is required.",
      );
    }

    const { data, error } = await admin.rpc("apply_revenuecat_event", {
      p_event_id: eventId,
      p_event_type: type,
      p_event_at: eventAt,
      p_original_transaction_id: originalTransactionId,
      p_app_user_id: appUserId,
      p_user_id: userId,
      p_aliases: aliases,
      p_entitlement_id: expectedEntitlement,
      p_product_id: productId || null,
      p_environment: environment,
      p_store: store,
      p_is_active: active,
      p_period_started_at: periodStartedAt,
      p_expires_at: expiresAt,
      p_reset_period: periodResetRequested(type, periodStartedAt),
    });
    if (error) {
      log(500, "rpc_failed", active ? "plus" : "none");
      // Non-2xx makes RevenueCat retry, which is what we want.
      return errorJson(500, "INTERNAL", "Could not apply entitlement.");
    }

    log(200, String(data?.outcome ?? "applied"), active ? "plus" : "none");
    return json(200, { ok: true, outcome: data?.outcome ?? "applied" });
  }),
};
