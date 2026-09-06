// Shared JSON response helpers. Error bodies follow the app contract:
// { "error": { "code": "...", "message": "..." }, "usage": { ... }? }

import { corsHeaders } from "./cors.ts";

export function json(
  status: number,
  body: unknown,
  request?: Request,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(request),
    },
  });
}

export function errorJson(
  status: number,
  code: string,
  message: string,
  options?: { usage?: unknown; extraHeaders?: Record<string, string> },
  request?: Request,
): Response {
  const body: Record<string, unknown> = { error: { code, message } };
  if (options?.usage !== undefined) {
    body.usage = options.usage;
  }
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...(options?.extraHeaders ?? {}),
      ...corsHeaders(request),
    },
  });
}
