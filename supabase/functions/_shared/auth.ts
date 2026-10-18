const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function authenticatedUserId(
  claims: { id?: unknown; sub?: unknown } | null,
): string {
  const candidate = claims?.id ?? claims?.sub;
  if (typeof candidate !== "string" || !UUID_PATTERN.test(candidate)) {
    // auth: "user" should make this unreachable. Failing closed avoids ever
    // falling back to an installation/client-provided identity.
    throw new Error("Authenticated JWT is missing a valid user id");
  }
  return candidate;
}

export function isUserId(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}
