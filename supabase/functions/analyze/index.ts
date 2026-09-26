// POST /functions/v1/analyze — honest read of a conversation.
//
// Same guarantees as generate: publishable-key auth, rate limit, validation,
// atomic quota (an analysis costs one full analysis), refund on AI failure,
// idempotent on request_id. Nothing about the conversation is stored or
// logged.

import { withSupabase } from "@supabase/server";
import { CANNED_ANALYSIS, produceAnalysis } from "../_shared/analysis.ts";
import {
  type GenerationRequestBody,
  validateAnalysisRequest,
} from "../_shared/contracts.ts";
import { handleOptions } from "../_shared/cors.ts";
import { configuredModel } from "../_shared/openai.ts";
import { preflight } from "../_shared/request.ts";
import { errorJson, json } from "../_shared/responses.ts";

export default {
  fetch: withSupabase({ auth: "publishable" }, async (req, ctx) => {
    const startedAt = Date.now();
    const requestLogId = crypto.randomUUID();
    const devSimulation = Deno.env.get("DEV_ERROR_SIMULATION") === "true";
    const scenario = req.headers.get("x-debug-scenario");
    const useCanned = devSimulation && scenario === "canned";

    const log = (status: number, category: string, metrics?: Record<string, unknown>) =>
      console.log(JSON.stringify({
        requestLogId,
        fn: "analyze",
        status,
        category,
        ms: Date.now() - startedAt,
        ...(metrics ?? {}),
      }));

    if (req.method === "OPTIONS") return handleOptions(req);
    if (req.method !== "POST") {
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use POST.", {}, req);
    }

    const pre = await preflight(req, ctx.supabaseAdmin);
    if (!pre.ok) {
      log(pre.response.status, pre.category);
      return pre.response;
    }

    const validation = validateAnalysisRequest(pre.parsed);
    if (!validation.ok) {
      log(400, "invalid_request");
      return errorJson(400, "INVALID_REQUEST", validation.message, {}, req);
    }
    const body = pre.parsed as GenerationRequestBody;

    const { data: reservation, error: reserveError } = await ctx.supabaseAdmin
      .rpc("reserve_usage", {
        p_installation_id: pre.installationId,
        p_request_id: body.request_id,
        p_action_kind: "generation",
      });
    if (reserveError || !reservation) {
      log(500, "reserve_failed");
      return errorJson(500, "INTERNAL", "Could not process request.", {}, req);
    }
    if (reservation.outcome === "quota_exceeded") {
      log(402, "quota_exceeded");
      return errorJson(402, "QUOTA_EXCEEDED", "No analyses remaining.", {
        usage: reservation.usage,
      }, req);
    }

    const isDuplicate = reservation.outcome === "duplicate";
    try {
      if (devSimulation && scenario === "fail_after_reserve") {
        throw new Error("simulated analysis failure");
      }

      let analysis = CANNED_ANALYSIS;
      let metrics: Record<string, unknown> = {};
      if (!useCanned) {
        const produced = await produceAnalysis(body);
        analysis = produced.analysis;
        metrics = {
          model: configuredModel(),
          inputTokens: produced.inputTokens,
          outputTokens: produced.outputTokens,
        };
      }

      if (isDuplicate) {
        log(200, "duplicate_request", metrics);
        return json(200, { analysis, usage: reservation.usage }, req);
      }

      const { data: commit, error: commitError } = await ctx.supabaseAdmin
        .rpc("commit_reservation", { p_reservation_id: reservation.reservation_id });
      log(200, commitError ? "commit_failed" : "analysis", metrics);
      return json(200, {
        analysis,
        usage: commitError ? reservation.usage : commit.usage,
      }, req);
    } catch {
      if (!isDuplicate) {
        await ctx.supabaseAdmin.rpc("release_reservation", {
          p_reservation_id: reservation.reservation_id,
        });
      }
      log(500, "analysis_failed_refunded");
      return errorJson(500, "ANALYSIS_FAILED", "Analysis failed.", {}, req);
    }
  }),
};
