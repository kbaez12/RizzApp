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

import { withSupabase } from "@supabase/server";
import { errorJson, json } from "../_shared/responses.ts";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Events that mean "entitled to Plus right now". CANCELLATION is
 * deliberately absent-but-entitled: it only means auto-renew was turned
 * off, and RevenueCat sends EXPIRATION when access actually ends.
 * BILLING_ISSUE keeps access during the grace period. */
const GRANTS_PLUS = new Set([
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
const REVOKES_PLUS = new Set(["EXPIRATION", "SUBSCRIPTION_PAUSED", "REFUND"]);

/** A new or renewed period resets the monthly allowance. */
const RESETS_PERIOD = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "NON_RENEWING_PURCHASE",
]);

export default {
  fetch: withSupabase({ auth: "none" }, async (req, ctx) => {
    if (req.method !== "POST") {
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use POST.");
    }

    const expected = Deno.env.get("REVENUECAT_WEBHOOK_SECRET");
    if (!expected || req.headers.get("Authorization") !== expected) {
      console.log(JSON.stringify({ fn: "revenuecat-webhook", status: 401 }));
      return errorJson(401, "UNAUTHORIZED", "Invalid webhook credentials.");
    }

    let payload: { event?: Record<string, unknown> };
    try {
      payload = await req.json();
    } catch {
      return errorJson(400, "INVALID_JSON", "Body must be valid JSON.");
    }

    const event = payload.event ?? {};
    const type = String(event.type ?? "");
    // We set the RevenueCat app user ID to our installation ID.
    const appUserId = String(event.app_user_id ?? "");
    const installationId = UUID_PATTERN.test(appUserId)
      ? appUserId
      : UUID_PATTERN.test(String(event.original_app_user_id ?? ""))
      ? String(event.original_app_user_id)
      : null;

    const log = (status: number, note: string, tier?: string) =>
      console.log(JSON.stringify({
        fn: "revenuecat-webhook",
        status,
        type,
        tier: tier ?? null,
        installationId,
        note,
      }));

    if (!installationId) {
      // Anonymous RevenueCat IDs ($RCAnonymousID:…) cannot be mapped to an
      // installation. Ack with 200 so RevenueCat stops retrying.
      log(200, "unmappable_app_user_id");
      return json(200, { ok: true, skipped: true });
    }

    let tier: "plus" | "free";
    if (REVOKES_PLUS.has(type)) {
      tier = "free";
    } else if (GRANTS_PLUS.has(type)) {
      tier = "plus";
    } else {
      // TRANSFER, SUBSCRIBER_ALIAS, TEST and anything new: acknowledge
      // without changing state.
      log(200, "ignored_event");
      return json(200, { ok: true, ignored: true });
    }

    const expirationMs = Number(event.expiration_at_ms ?? 0);
    const expiresAt = tier === "plus" && expirationMs > 0
      ? new Date(expirationMs).toISOString()
      : null;

    const { error } = await ctx.supabaseAdmin.rpc("apply_entitlement", {
      p_installation_id: installationId,
      p_tier: tier,
      p_expires_at: expiresAt,
      p_reset_period: RESETS_PERIOD.has(type),
    });
    if (error) {
      log(500, "rpc_failed", tier);
      // Non-2xx makes RevenueCat retry, which is what we want.
      return errorJson(500, "INTERNAL", "Could not apply entitlement.");
    }

    log(200, "applied", tier);
    return json(200, { ok: true });
  }),
};
