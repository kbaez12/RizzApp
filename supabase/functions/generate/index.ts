// POST /functions/v1/generate
//
// Supabase user JWT authentication via @supabase/server. Quota is enforced
// atomically in Postgres through a
// reserve → generate → commit/release pipeline: an OpenAI failure refunds
// the user's usage.
//
// Logging policy: request id, status, duration, category, input kind,
// model, token counts. NEVER conversation text, base64, prompts, or
// generated replies.

import { withSupabase } from "npm:@supabase/server@1";
import { produceReplies } from "../_shared/generation.ts";
import { configuredModel } from "../_shared/openai.ts";
import { preflight } from "../_shared/request.ts";
import {
  classifyAction,
  type GenerationRequestBody,
  validateGenerationRequest,
} from "../_shared/contracts.ts";
import { errorJson, json } from "../_shared/responses.ts";
import { handleOptions } from "../_shared/cors.ts";
import { performReservedOperation } from "../_shared/idempotency.ts";
import {
  CANNED_REFINED,
  CANNED_RESPONSES,
  CANNED_USAGE_EXHAUSTED,
} from "../_shared/canned.ts";
import { authenticatedUserId } from "../_shared/auth.ts";
import { reservationDenial } from "../_shared/subscription.ts";

// Development-only error simulation (requires DEV_ERROR_SIMULATION=true in
// the function env — local .env only, never production). Note: these run
// AFTER real authentication; to test true 401s, send an invalid apikey.
// Remove this mechanism before production exposure.
function simulatedResponse(scenario: string, req: Request): Response | null {
  switch (scenario) {
    case "invalid_request":
      return errorJson(
        400,
        "INVALID_REQUEST",
        "Simulated bad request.",
        {},
        req,
      );
    case "unauthorized":
      return errorJson(401, "UNAUTHORIZED", "Simulated auth failure.", {}, req);
    case "quota":
      return errorJson(429, "USAGE_LIMIT_EXCEEDED", "Monthly usage limit reached.", {
        usage: CANNED_USAGE_EXHAUSTED,
      }, req);
    case "rate_limit":
      return errorJson(429, "RATE_LIMITED", "Slow down.", {
        extraHeaders: { "Retry-After": "30" },
      }, req);
    case "server_error":
      return errorJson(500, "INTERNAL", "Simulated server error.", {}, req);
    case "malformed":
      return new Response("this is not json {", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    default:
      // "fail_after_reserve" is handled inside the pipeline so the refund
      // path is genuinely exercised.
      return null;
  }
}

/** Canned replies are retained ONLY for the dev "canned" debug scenario, so
 * quota/idempotency integration tests can run without spending OpenAI calls. */
function cannedResponses(body: GenerationRequestBody) {
  return body.refinement
    ? CANNED_REFINED[body.refinement] ?? CANNED_RESPONSES
    : CANNED_RESPONSES;
}

export default {
  fetch: withSupabase({ auth: "user" }, async (req, ctx) => {
    const startedAt = Date.now();
    const requestLogId = crypto.randomUUID();
    const devSimulation = Deno.env.get("DEV_ERROR_SIMULATION") === "true";
    // New additive RPCs are not present in @supabase/server's ungenerated
    // Database type. Keep this cast scoped to the trusted service-role client.
    // deno-lint-ignore no-explicit-any
    const admin = ctx.supabaseAdmin as any;

    const log = (
      status: number,
      category: string,
      kind?: string,
      metrics?: Record<string, unknown>,
    ) => {
      console.log(JSON.stringify({
        requestLogId,
        fn: "generate",
        status,
        category,
        kind: kind ?? null,
        ms: Date.now() - startedAt,
        ...(metrics ?? {}),
      }));
    };

    if (req.method === "OPTIONS") {
      return handleOptions(req);
    }
    if (req.method !== "POST") {
      log(405, "method_not_allowed");
      return errorJson(405, "METHOD_NOT_ALLOWED", "Use POST.", {}, req);
    }

    const scenario = req.headers.get("x-debug-scenario");
    if (scenario && devSimulation) {
      const simulated = simulatedResponse(scenario, req);
      if (simulated) {
        log(simulated.status, `simulated_${scenario}`);
        return simulated;
      }
    }

    const userId = authenticatedUserId(ctx.userClaims);
    const pre = await preflight(req, admin, userId);
    if (!pre.ok) {
      log(pre.response.status, pre.category);
      return pre.response;
    }
    const { parsed } = pre;

    const validation = validateGenerationRequest(parsed);
    if (!validation.ok) {
      log(400, "invalid_request");
      return errorJson(400, "INVALID_REQUEST", validation.message, {}, req);
    }

    const body = parsed as GenerationRequestBody;
    const actionKind = classifyAction(body);

    // ---- RESERVE (atomic, in Postgres; idempotent per request_id) ----
    const { data: reservation, error: reserveError } = await admin
      .rpc("reserve_user_usage", {
        p_user_id: userId,
        p_request_id: body.request_id,
        p_action_kind: actionKind,
      });
    if (reserveError || !reservation) {
      log(500, "reserve_failed");
      return errorJson(500, "INTERNAL", "Could not process request.", {}, req);
    }

    const denial = reservationDenial(reservation.outcome);
    if (denial) {
      log(denial.status, denial.category, body.input?.kind);
      return errorJson(denial.status, denial.code, denial.message, {
        usage: reservation.usage,
      }, req);
    }

    // ---- GENERATE (real OpenAI; refunds on failure) ----
    try {
      const guarded = await performReservedOperation(
        reservation,
        req,
        async () => {
          if (scenario === "fail_after_reserve" && devSimulation) {
            throw new Error("simulated generation failure");
          }

          if (scenario === "canned" && devSimulation) {
            // Dev-only: exercises quota/idempotency without spending API calls.
            return {
              responses: cannedResponses(body),
              metrics: {} as Record<string, unknown>,
            };
          }

          const produced = await produceReplies(body);
          return {
            responses: produced.responses,
            metrics: {
              model: configuredModel(),
              inputTokens: produced.inputTokens,
              outputTokens: produced.outputTokens,
              retried: produced.retried,
              remainingProblems: produced.remainingProblems,
            },
          };
        },
      );

      if (!guarded.performed) {
        log(409, "duplicate_request", body.input?.kind, {
          priorStatus: reservation.prior_status ?? null,
        });
        return guarded.response;
      }
      const { responses, metrics } = guarded.value;

      // ---- COMMIT ----
      const { data: commit, error: commitError } = await admin
        .rpc("commit_user_reservation", {
          p_reservation_id: reservation.reservation_id,
        });
      if (commitError) {
        // Work succeeded but commit failed — return the result anyway with
        // the reserve-time usage; reservation will expire → auto-release
        // (we favor the user over double-charging).
        log(200, "commit_failed", body.input?.kind, metrics);
        return json(200, { responses, usage: reservation.usage }, req);
      }

      log(200, actionKind, body.input?.kind, metrics);
      return json(200, { responses, usage: commit.usage }, req);
    } catch {
      // ---- RELEASE / REFUND: user never loses quota to a server failure.
      await admin.rpc("release_user_reservation", {
        p_reservation_id: reservation.reservation_id,
      });
      log(500, "generation_failed_refunded", body.input?.kind);
      return errorJson(500, "GENERATION_FAILED", "Generation failed.", {}, req);
    }
  }),
};
