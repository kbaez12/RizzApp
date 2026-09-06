// POST /functions/v1/generate — Phase 4A: canned responses only.
//
// Validates the request shape and returns deterministic data. Does NOT:
// call any AI provider, store screenshots or text, write conversation data
// anywhere, decode image pixels, or log conversation contents.
//
// Logging policy: request id, status, duration, input kind, error category.
// NEVER text, base64, or generated replies.

import {
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
  CANNED_USAGE_AFTER_GENERATE,
  CANNED_USAGE_EXHAUSTED,
} from "../_shared/canned.ts";

/// Development-only error simulation, enabled ONLY when the function runs
/// with DEV_ERROR_SIMULATION=true (local .env; never set in production).
/// Remove this mechanism before production exposure.
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
      return null;
  }
}

Deno.serve(async (req) => {
  const startedAt = Date.now();
  const requestId = crypto.randomUUID();

  const log = (status: number, category: string, kind?: string) => {
    console.log(JSON.stringify({
      requestId,
      fn: "generate",
      status,
      category,
      kind: kind ?? null,
      ms: Date.now() - startedAt,
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
  if (scenario && Deno.env.get("DEV_ERROR_SIMULATION") === "true") {
    const simulated = simulatedResponse(scenario, req);
    if (simulated) {
      log(simulated.status, `simulated_${scenario}`);
      return simulated;
    }
  }

  if (!req.headers.get("apikey")) {
    log(401, "missing_apikey");
    return errorJson(401, "UNAUTHORIZED", "Missing API key.", {}, req);
  }

  if (!isValidInstallationId(req.headers.get("x-installation-id"))) {
    log(400, "invalid_installation_id");
    return errorJson(
      400,
      "INVALID_INSTALLATION",
      "Missing or invalid installation identifier.",
      {},
      req,
    );
  }

  const contentLength = Number(req.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) {
    log(400, "payload_too_large");
    return errorJson(400, "PAYLOAD_TOO_LARGE", "Request body too large.", {}, req);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    log(400, "invalid_json");
    return errorJson(400, "INVALID_JSON", "Body must be valid JSON.", {}, req);
  }

  const validation = validateGenerationRequest(body);
  if (!validation.ok) {
    log(400, "invalid_request");
    return errorJson(400, "INVALID_REQUEST", validation.message, {}, req);
  }

  const request = body as GenerationRequestBody;
  const refinement = request.refinement ?? null;
  const responses = refinement
    ? CANNED_REFINED[refinement] ?? CANNED_RESPONSES
    : CANNED_RESPONSES;

  log(200, refinement ? "refinement" : "generation", request.input?.kind);
  return json(200, { responses, usage: CANNED_USAGE_AFTER_GENERATE }, req);
});
