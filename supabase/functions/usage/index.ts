// GET /functions/v1/usage — Phase 4B: authoritative Postgres-backed usage.
//
// Publishable-key authentication via @supabase/server. Creates the
// installation row on first contact (concurrency-safe upsert in the RPC).
// No conversation content is involved anywhere in this endpoint.

import { withSupabase } from "@supabase/server";
import { errorJson, json } from "../_shared/responses.ts";
import { handleOptions } from "../_shared/cors.ts";
import { isValidInstallationId } from "../_shared/contracts.ts";

export default {
  fetch: withSupabase({ auth: "publishable" }, async (req, ctx) => {
    if (req.method === "OPTIONS") {
      return handleOptions(req);
    }
    if (req.method !== "GET") {
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use GET.", {}, req);
    }

    const installationId = req.headers.get("x-installation-id");
    if (!isValidInstallationId(installationId)) {
      return errorJson(
        400,
        "INVALID_INSTALLATION",
        "Missing or invalid installation identifier.",
        {},
        req,
      );
    }

    const { data: usage, error } = await ctx.supabaseAdmin.rpc("get_usage", {
      p_installation_id: installationId,
    });
    if (error || !usage) {
      console.log(JSON.stringify({ fn: "usage", status: 500, category: "rpc_failed" }));
      return errorJson(500, "INTERNAL", "Could not load usage.", {}, req);
    }

    return json(200, usage, req);
  }),
};
