// POST /functions/v1/generate
//
// Publishable-key authentication via @supabase/server (withSupabase
// validates the `apikey` header against the project's publishable key with
// a timing-safe comparison; verify_jwt = false remains correct for this
// no-user-JWT flow). Quota is enforced atomically in Postgres through a
// reserve → generate → commit/release pipeline: an OpenAI failure refunds
// the user's usage.
//
// Logging policy: request id, status, duration, category, input kind,
// model, token counts. NEVER conversation text, base64, prompts, or
// generated replies.

import { withSupabase } from "@supabase/server";
import { produceReplies } from "../_shared/generation.ts";
import { configuredModel } from "../_shared/openai.ts";
import { enforceRateLimit } from "../_shared/rate_limit.ts";
import {
  classifyAction,
  type GenerationRequestBody,
  isValidInstallationId,
  MAX_BODY_BYTES,
  validateGenerationRequest,
} from "../_shared/contracts.ts";
import { errorJson, json } from "../_shared/responses.ts";
import { handleOptions } from "../_shared/cors.ts";
import {
  CANNED_REFINED,
  CANNED_RESPONSES,
  CANNED_USAGE_EXHAUSTED,
} from "../_shared/canned.ts";

// Development-only error simulation (requires DEV_ERROR_SIMULATION=true in
// the function env — local .env only, never production). Note: these run
// AFTER real authentication; to test true 401s, send an invalid apikey.
// Remove this mechanism before production exposure.
function simulatedResponse(scenario: string, req: Request): Response | null {
  switch (scenario) {
    case "invalid_request":
      return errorJson(400, "INVALID_REQUEST", "Simulated bad request.", {}, req);
    case "unauthorized":
      return errorJson(401, "UNAUTHORIZED", "Simulated auth failure.", {}, req);
    case "quota":
      return errorJson(402, "QUOTA_EXCEEDED", "No analyses remaining.", {
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
  fetch: withSupabase({ auth: "publishable" }, async (req, ctx) => {
    const startedAt = Date.now();
    const requestLogId = crypto.randomUUID();
    const devSimulation = Deno.env.get("DEV_ERROR_SIMULATION") === "true";

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

    const installationId = req.headers.get("x-installation-id");
    if (!isValidInstallationId(installationId)) {
      log(400, "invalid_installation_id");
      return errorJson(
        400,
        "INVALID_INSTALLATION",
        "Missing or invalid installation identifier.",
        {},
        req,
      );
    }

    // Cheap per-installation rate limit before any expensive work.
    const rate = await enforceRateLimit(ctx.supabaseAdmin, installationId!);
    if (!rate.allowed) {
      log(429, "rate_limited");
      return errorJson(429, "RATE_LIMITED", "Too many requests.", {
        extraHeaders: { "Retry-After": String(rate.retryAfterSeconds) },
      }, req);
    }

    const contentLength = Number(req.headers.get("content-length") ?? "0");
    if (contentLength > MAX_BODY_BYTES) {
      log(400, "payload_too_large");
      return errorJson(400, "PAYLOAD_TOO_LARGE", "Request body too large.", {}, req);
    }

    let parsed: unknown;
    try {
      parsed = await req.json();
    } catch {
      log(400, "invalid_json");
      return errorJson(400, "INVALID_JSON", "Body must be valid JSON.", {}, req);
    }

    const validation = validateGenerationRequest(parsed);
    if (!validation.ok) {
      log(400, "invalid_request");
      return errorJson(400, "INVALID_REQUEST", validation.message, {}, req);
    }

    const body = parsed as GenerationRequestBody;
    const actionKind = classifyAction(body);

    // ---- RESERVE (atomic, in Postgres; idempotent per request_id) ----
    const { data: reservation, error: reserveError } = await ctx.supabaseAdmin
      .rpc("reserve_usage", {
        p_installation_id: installationId,
        p_request_id: body.request_id,
        p_action_kind: actionKind,
      });
    if (reserveError || !reservation) {
      log(500, "reserve_failed");
      return errorJson(500, "INTERNAL", "Could not process request.", {}, req);
    }

    if (reservation.outcome === "quota_exceeded") {
      log(402, "quota_exceeded", body.input?.kind);
      return errorJson(402, "QUOTA_EXCEEDED", "No analyses remaining.", {
        usage: reservation.usage,
      }, req);
    }

    if (reservation.outcome === "duplicate") {
      // Idempotent retry: quota was already decided. We do not store
      // generated replies (privacy), so we regenerate without charging.
      // Dev "canned" scenario still returns the fixture set.
      try {
        const responses = scenario === "canned" && devSimulation
          ? cannedResponses(body)
          : (await produceReplies(body)).responses;
        log(200, "duplicate_request", body.input?.kind);
        return json(200, { responses, usage: reservation.usage }, req);
      } catch {
        log(500, "duplicate_regenerate_failed", body.input?.kind);
        return errorJson(500, "GENERATION_FAILED", "Generation failed.", {}, req);
      }
    }

    // ---- GENERATE (real OpenAI; refunds on failure) ----
    try {
      if (scenario === "fail_after_reserve" && devSimulation) {
        throw new Error("simulated generation failure");
      }

      let responses;
      let metrics: Record<string, unknown> = {};
      if (scenario === "canned" && devSimulation) {
        // Dev-only: exercises quota/idempotency without spending API calls.
        responses = cannedResponses(body);
      } else {
        const produced = await produceReplies(body);
        responses = produced.responses;
        metrics = {
          model: configuredModel(),
          inputTokens: produced.inputTokens,
          outputTokens: produced.outputTokens,
          retried: produced.retried,
          remainingProblems: produced.remainingProblems,
        };
      }

      // ---- COMMIT ----
      const { data: commit, error: commitError } = await ctx.supabaseAdmin
        .rpc("commit_reservation", {
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
      await ctx.supabaseAdmin.rpc("release_reservation", {
        p_reservation_id: reservation.reservation_id,
      });
      log(500, "generation_failed_refunded", body.input?.kind);
      return errorJson(500, "GENERATION_FAILED", "Generation failed.", {}, req);
    }
  }),
};
