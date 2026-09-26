// Common request checks for app-facing POST endpoints (generate, analyze):
// installation ID, per-installation rate limit, body size, JSON parsing.
// Endpoint-specific validation happens after this.

import { isValidInstallationId, MAX_BODY_BYTES } from "./contracts.ts";
import { enforceRateLimit } from "./rate_limit.ts";
import { errorJson } from "./responses.ts";

export type Preflight =
  | { ok: true; installationId: string; parsed: unknown }
  | { ok: false; response: Response; category: string };

export async function preflight(
  req: Request,
  // deno-lint-ignore no-explicit-any
  admin: any,
): Promise<Preflight> {
  const installationId = req.headers.get("x-installation-id");
  if (!isValidInstallationId(installationId)) {
    return {
      ok: false,
      category: "invalid_installation_id",
      response: errorJson(
        400,
        "INVALID_INSTALLATION",
        "Missing or invalid installation identifier.",
        {},
        req,
      ),
    };
  }

  const rate = await enforceRateLimit(admin, installationId!);
  if (!rate.allowed) {
    return {
      ok: false,
      category: "rate_limited",
      response: errorJson(429, "RATE_LIMITED", "Too many requests.", {
        extraHeaders: { "Retry-After": String(rate.retryAfterSeconds) },
      }, req),
    };
  }

  const contentLength = Number(req.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) {
    return {
      ok: false,
      category: "payload_too_large",
      response: errorJson(400, "PAYLOAD_TOO_LARGE", "Request body too large.", {}, req),
    };
  }

  try {
    return { ok: true, installationId: installationId!, parsed: await req.json() };
  } catch {
    return {
      ok: false,
      category: "invalid_json",
      response: errorJson(400, "INVALID_JSON", "Body must be valid JSON.", {}, req),
    };
  }
}
