// POST /functions/v1/analyze — honest read of a conversation.
//
// Same guarantees as generate: user-JWT auth, rate limit, validation,
// atomic quota (an analysis costs one full analysis), refund on AI failure,
// idempotent on request_id. Nothing about the conversation is stored or
// logged.

import { withSupabase } from "npm:@supabase/server@1";
import { CANNED_ANALYSIS, produceAnalysis } from "../_shared/analysis.ts";
import {
  type GenerationRequestBody,
  validateAnalysisRequest,
} from "../_shared/contracts.ts";
import { handleOptions } from "../_shared/cors.ts";
import { configuredModel } from "../_shared/openai.ts";
import { preflight } from "../_shared/request.ts";
import { errorJson, json } from "../_shared/responses.ts";
import { performReservedOperation } from "../_shared/idempotency.ts";
import { authenticatedUserId } from "../_shared/auth.ts";
import { reservationDenial } from "../_shared/subscription.ts";

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const startedAt = Date.now();
    const requestLogId = crypto.randomUUID();
    const devSimulation = Deno.env.get("DEV_ERROR_SIMULATION") === "true";
    // deno-lint-ignore no-explicit-any
    const admin = ctx.supabaseAdmin as any;
    const scenario = req.headers.get("x-debug-scenario");
    const useCanned = devSimulation && scenario === "canned";

    const log = (
      status: number,
      category: string,
      metrics?: Record<string, unknown>,
    ) =>
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

    const userId = authenticatedUserId(ctx.userClaims);
    const pre = await preflight(req, admin, userId);
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

    const { data: reservation, error: reserveError } = await admin
      .rpc("reserve_user_usage", {
        p_user_id: userId,
        p_request_id: body.request_id,
        p_action_kind: "generation",
      });
    if (reserveError || !reservation) {
      log(500, "reserve_failed");
      return errorJson(500, "INTERNAL", "Could not process request.", {}, req);
    }
    const denial = reservationDenial(reservation.outcome);
    if (denial) {
      log(denial.status, denial.category);
      return errorJson(denial.status, denial.code, denial.message, {
        usage: reservation.usage,
      }, req);
    }

    try {
      const guarded = await performReservedOperation(
        reservation,
        req,
        async () => {
          if (devSimulation && scenario === "fail_after_reserve") {
            throw new Error("simulated analysis failure");
          }

          if (useCanned) {
            return {
              analysis: CANNED_ANALYSIS,
              metrics: {} as Record<string, unknown>,
            };
          }

          const produced = await produceAnalysis(body);
          return {
            analysis: produced.analysis,
            metrics: {
              model: configuredModel(),
              inputTokens: produced.inputTokens,
              outputTokens: produced.outputTokens,
            },
          };
        },
      );

      if (!guarded.performed) {
        log(409, "duplicate_request", {
          priorStatus: reservation.prior_status ?? null,
        });
        return guarded.response;
      }
      const { analysis, metrics } = guarded.value;

      const { data: commit, error: commitError } = await admin
        .rpc("commit_user_reservation", {
          p_reservation_id: reservation.reservation_id,
        });
      log(200, commitError ? "commit_failed" : "analysis", metrics);
      return json(200, {
        analysis,
        usage: commitError ? reservation.usage : commit.usage,
      }, req);
    } catch {
      await admin.rpc("release_user_reservation", {
        p_reservation_id: reservation.reservation_id,
      });
      log(500, "analysis_failed_refunded");
      return errorJson(500, "ANALYSIS_FAILED", "Analysis failed.", {}, req);
    }
  }),
};
