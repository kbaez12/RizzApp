// POST /functions/v1/subscription-sync
//
// The authenticated JWT supplies the only user identity. Subscription state
// is fetched server-to-server from RevenueCat; request-body premium flags,
// products, expirations, and transaction identifiers are never accepted.

import { withSupabase } from "npm:@supabase/server@1";
import { authenticatedUserId } from "../_shared/auth.ts";
import { errorJson, json } from "../_shared/responses.ts";
import {
  fetchRevenueCatSubscription,
  periodResetRequested,
} from "../_shared/revenuecat.ts";

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    if (req.method !== "POST") {
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use POST.", {}, req);
    }

    const userId = authenticatedUserId(ctx.userClaims);
    // deno-lint-ignore no-explicit-any
    const admin = ctx.supabaseAdmin as any;
    let state;
    try {
      state = await fetchRevenueCatSubscription(userId);
    } catch (error) {
      console.log(JSON.stringify({
        fn: "subscription-sync",
        status: 502,
        category: "revenuecat_lookup_failed",
        message: error instanceof Error ? error.message : "unknown",
      }));
      return errorJson(
        502,
        "SUBSCRIPTION_SYNC_FAILED",
        "Could not verify subscription.",
        {},
        req,
      );
    }

    const expectedEntitlement = Deno.env.get("REVENUECAT_ENTITLEMENT_ID")!
      .trim();
    const expectedEnvironment =
      Deno.env.get("REVENUECAT_EXPECTED_ENVIRONMENT")?.trim();
    const expectedStore = Deno.env.get("REVENUECAT_EXPECTED_STORE")?.trim();
    if (
      !expectedEnvironment || !expectedStore ||
      state.environment.toUpperCase() !== expectedEnvironment.toUpperCase() ||
      state.store.toUpperCase() !== expectedStore.toUpperCase()
    ) {
      return errorJson(
        502,
        "SUBSCRIPTION_SYNC_FAILED",
        "RevenueCat returned an unexpected subscription source.",
        {},
        req,
      );
    }

    const now = new Date().toISOString();
    const eventId = `sync:${userId}:${crypto.randomUUID()}`;
    // RevenueCat's v1 subscriber API confirms current entitlement but does
    // not expose Apple's original_transaction_id. Use a clearly provisional
    // key so access can unlock immediately; the first trusted lifecycle
    // webhook replaces it in-place with the stable Apple transaction ID.
    const billingKey = state.active
      ? state.originalTransactionId ?? `pending:${userId}`
      : "";
    const { error } = await admin.rpc("apply_revenuecat_event", {
      p_event_id: eventId,
      p_event_type: "SERVER_SYNC",
      p_event_at: now,
      p_original_transaction_id: billingKey,
      p_app_user_id: userId,
      p_user_id: userId,
      p_aliases: [userId],
      p_entitlement_id: expectedEntitlement,
      p_product_id: state.productId,
      p_environment: expectedEnvironment,
      p_store: expectedStore,
      p_is_active: state.active,
      p_period_started_at: state.periodStartedAt,
      p_expires_at: state.expiresAt,
      // SERVER_SYNC confirms current entitlement. It is not a billing-period
      // boundary. A missing RevenueCat period start must never become now().
      p_reset_period: periodResetRequested("SERVER_SYNC", state.periodStartedAt),
    });
    if (error) {
      console.log(JSON.stringify({
        fn: "subscription-sync",
        status: 500,
        category: "rpc_failed",
      }));
      return errorJson(500, "INTERNAL", "Could not save subscription.", {}, req);
    }

    const { data: usage, error: usageError } = await admin.rpc(
      "get_user_usage",
      { p_user_id: userId },
    );
    if (usageError || !usage) {
      return errorJson(500, "INTERNAL", "Could not load usage.", {}, req);
    }
    return json(200, usage, req);
  }),
};
