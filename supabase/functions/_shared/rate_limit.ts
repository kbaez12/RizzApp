// Per-authenticated-user rate limiting. Fail closed: an infrastructure
// outage must not remove spending protection from expensive AI endpoints.

export interface RateLimitDecision {
  allowed: boolean;
  retryAfterSeconds: number;
}

// deno-lint-ignore no-explicit-any
export async function enforceRateLimit(
  admin: any,
  userId: string,
): Promise<RateLimitDecision> {
  const { data, error } = await admin.rpc("check_rate_limit", {
    p_installation_id: userId,
  });
  if (error || !data) {
    return { allowed: false, retryAfterSeconds: 30 };
  }
  return {
    allowed: data.allowed !== false,
    retryAfterSeconds: Number(data.retry_after_seconds ?? 0),
  };
}
