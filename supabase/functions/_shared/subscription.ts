// Reservation outcomes that must stop expensive model work.
// generate/analyze call this before performReservedOperation / OpenAI.

export interface ReservationDenial {
  status: number;
  code: string;
  message: string;
  category: string;
}

export function reservationDenial(outcome: string): ReservationDenial | null {
  if (outcome === "subscription_required") {
    return {
      status: 402,
      code: "SUBSCRIPTION_REQUIRED",
      message: "An active subscription is required.",
      category: "subscription_required",
    };
  }
  if (outcome === "usage_limit_exceeded") {
    return {
      status: 429,
      code: "USAGE_LIMIT_EXCEEDED",
      message: "Monthly usage limit reached.",
      category: "usage_limit_exceeded",
    };
  }
  return null;
}

/** OpenAI is allowed only after Postgres returns a fresh reservation. */
export function reservationAllowsModelCall(outcome: string): boolean {
  return outcome === "reserved";
}
