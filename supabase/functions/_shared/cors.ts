// CORS handling — deliberately narrow.
//
// Our primary client is a native iOS app using URLSession, which does not
// enforce CORS at all; these headers are irrelevant to it. They exist only
// so local browser-based dev tools can hit the local stack. We therefore
// echo ONLY loopback origins instead of blanket `*`. Revisit before any
// web client ever exists.

const ALLOWED_HEADERS =
  "apikey, content-type, x-installation-id, x-debug-scenario";

function isLoopbackOrigin(origin: string): boolean {
  return (
    origin.startsWith("http://localhost") ||
    origin.startsWith("http://127.0.0.1")
  );
}

export function corsHeaders(request?: Request): Record<string, string> {
  const origin = request?.headers.get("Origin");
  if (!origin || !isLoopbackOrigin(origin)) {
    return {};
  }
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": ALLOWED_HEADERS,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

export function handleOptions(request: Request): Response {
  return new Response(null, { status: 204, headers: corsHeaders(request) });
}
