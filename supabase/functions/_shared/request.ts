// Common request checks for authenticated app-facing POST endpoints:
// per-user rate limit, body size, and JSON parsing.
// Endpoint-specific validation happens after this.

import { MAX_BODY_BYTES } from "./contracts.ts";
import { enforceRateLimit } from "./rate_limit.ts";
import { errorJson } from "./responses.ts";

export type Preflight =
  | { ok: true; userId: string; parsed: unknown }
  | { ok: false; response: Response; category: string };

export async function preflight(
  req: Request,
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
): Promise<Preflight> {
  const rate = await enforceRateLimit(admin, userId);
  if (!rate.allowed) {
    return {
      ok: false,
      category: "rate_limited",
      response: errorJson(429, "RATE_LIMITED", "Too many requests.", {
        extraHeaders: { "Retry-After": String(rate.retryAfterSeconds) },
      }, req),
    };
  }

  const declaredLength = Number(req.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) {
    return {
      ok: false,
      category: "payload_too_large",
      response: errorJson(400, "PAYLOAD_TOO_LARGE", "Request body too large.", {}, req),
    };
  }

  try {
    // Content-Length is optional and client-controlled. Measure the bytes
    // actually received before parsing so chunked requests cannot bypass the
    // expensive-endpoint payload cap.
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.byteLength > MAX_BODY_BYTES) {
      return {
        ok: false,
        category: "payload_too_large",
        response: errorJson(
          400,
          "PAYLOAD_TOO_LARGE",
          "Request body too large.",
          {},
          req,
        ),
      };
    }
    const text = new TextDecoder().decode(bytes);
    return { ok: true, userId, parsed: JSON.parse(text) };
  } catch {
    return {
      ok: false,
      category: "invalid_json",
      response: errorJson(400, "INVALID_JSON", "Body must be valid JSON.", {}, req),
    };
  }
}
