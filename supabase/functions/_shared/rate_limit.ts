// Per-installation rate limiting. Fail-open by design: a limiter outage
// must not take generation down, since quota enforcement is the real
// spending cap.

export interface RateLimitDecision {
  allowed: boolean;
  retryAfterSeconds: number;
}

// deno-lint-ignore no-explicit-any
export async function enforceRateLimit(
  admin: any,
  installationId: string,
): Promise<RateLimitDecision> {
  const { data, error } = await admin.rpc("check_rate_limit", {
    p_installation_id: installationId,
  });
  if (error || !data) {
    return { allowed: true, retryAfterSeconds: 0 };
  }
  return {
    allowed: data.allowed !== false,
    retryAfterSeconds: Number(data.retry_after_seconds ?? 0),
  };
}
