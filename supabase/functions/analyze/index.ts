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
import { errorJson } from "../_shared/responses.ts";
import { deliverReservedOperation } from "../_shared/idempotency.ts";
import { authenticatedUserId } from "../_shared/auth.ts";
import { reservationDenial } from "../_shared/subscription.ts";

// Export the authenticated handler for focused RPC/model failure tests.
export async function handleAnalyze(
  req: Request,
  ctx: {
    supabaseAdmin: unknown;
    userClaims: { id?: unknown; sub?: unknown } | null;
  },
  produce = produceAnalysis,
): Promise<Response> {
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

  let reservation;
  let reserveError;
  try {
    ({ data: reservation, error: reserveError } = await admin
      .rpc("reserve_user_usage", {
        p_user_id: userId,
        p_request_id: body.request_id,
        p_action_kind: "generation",
      }));
  } catch {
    log(503, "reserve_unconfirmed");
    return errorJson(
      503,
      "ACCOUNTING_UNCONFIRMED",
      "Could not confirm reservation. Retry with the same request ID.",
      {},
      req,
    );
  }
  if (reserveError || !reservation) {
    log(500, "reserve_failed");
    return errorJson(
      503,
      "ACCOUNTING_UNCONFIRMED",
      "Could not confirm reservation. Retry with the same request ID.",
      {},
      req,
    );
  }
  const denial = reservationDenial(reservation.outcome);
  if (denial) {
    log(denial.status, denial.category);
    return errorJson(denial.status, denial.code, denial.message, {
      usage: reservation.usage,
    }, req);
  }

  return await deliverReservedOperation(
    admin,
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

      const produced = await produce(body);
      return {
        analysis: produced.analysis,
        metrics: {
          model: configuredModel(),
          inputTokens: produced.inputTokens,
          outputTokens: produced.outputTokens,
        },
      };
    },
    (value) => ({ analysis: value.analysis }),
    "ANALYSIS_FAILED",
    (status, category, value) =>
      log(status, category, {
        reservationId: reservation.reservation_id,
        ...value?.metrics,
      }),
  );
}

export default {
  fetch: withSupabase({ auth: "user" }, (req, ctx) => handleAnalyze(req, ctx)),
};
