// GET /functions/v1/usage — Phase 4A: canned development usage only.
// NOT production-authoritative quota. Phase 4B adds real persistence and
// atomic consumption.

import { errorJson, json } from "../_shared/responses.ts";
import { handleOptions } from "../_shared/cors.ts";
import { CANNED_USAGE_INITIAL } from "../_shared/canned.ts";
import { isValidInstallationId } from "../_shared/contracts.ts";

Deno.serve((req) => {
  if (req.method === "OPTIONS") {
    return handleOptions(req);
  }
  if (req.method !== "GET") {
    return errorJson(405, "METHOD_NOT_ALLOWED", "Use GET.", {}, req);
  }
  if (!req.headers.get("apikey")) {
    return errorJson(401, "UNAUTHORIZED", "Missing API key.", {}, req);
  }
  if (!isValidInstallationId(req.headers.get("x-installation-id"))) {
    return errorJson(
      400,
      "INVALID_INSTALLATION",
      "Missing or invalid installation identifier.",
      {},
      req,
    );
  }

  return json(200, CANNED_USAGE_INITIAL, req);
});
