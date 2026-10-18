// GET /functions/v1/usage — authenticated subscription and quota status.

import { withSupabase } from "npm:@supabase/server@1";
import { errorJson, json } from "../_shared/responses.ts";
import { handleOptions } from "../_shared/cors.ts";
import { authenticatedUserId } from "../_shared/auth.ts";

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    if (req.method === "OPTIONS") {
      return handleOptions(req);
    }
    if (req.method !== "GET") {
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use GET.", {}, req);
    }

    const userId = authenticatedUserId(ctx.userClaims);
    // deno-lint-ignore no-explicit-any
    const admin = ctx.supabaseAdmin as any;
    const { data: usage, error } = await admin.rpc("get_user_usage", {
      p_user_id: userId,
    });
    if (error || !usage) {
      console.log(JSON.stringify({ fn: "usage", status: 500, category: "rpc_failed" }));
      return errorJson(500, "INTERNAL", "Could not load usage.", {}, req);
    }

    return json(200, usage, req);
  }),
};
