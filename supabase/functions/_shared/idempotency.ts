import { errorJson, json } from "./responses.ts";

export interface UsageReservation {
  outcome: string;
  reservation_id?: string;
  prior_status?: string;
  usage?: unknown;
}

export type ReservedOperation<T> =
  | { performed: true; value: T }
  | { performed: false; response: Response };

/**
 * Runs expensive work only for a newly reserved request. Postgres serializes
 * reservations per installation, so concurrent callers with the same request
 * ID all receive `duplicate` except the single winner.
 *
 * Duplicate results cannot be replayed because conversation output is never
 * persisted. Retrying an ID never generates or charges a second time.
 */
export async function performReservedOperation<T>(
  reservation: UsageReservation,
  request: Request,
  operation: () => Promise<T>,
): Promise<ReservedOperation<T>> {
  if (reservation.outcome === "duplicate") {
    return {
      performed: false,
      response: errorJson(
        409,
        "DUPLICATE_REQUEST",
        "This request was already accepted. Output cannot be replayed. Refresh usage before choosing to start a new request.",
        { usage: reservation.usage },
        request,
      ),
    };
  }

  if (reservation.outcome !== "reserved" || !reservation.reservation_id) {
    return {
      performed: false,
      response: errorJson(
        503,
        "ACCOUNTING_UNAVAILABLE",
        "Could not confirm a reservation. Retry with the same request ID.",
        {},
        request,
      ),
    };
  }

  return { performed: true, value: await operation() };
}

export interface ReservationClient {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<
    {
      data: { outcome?: string; status?: string; usage?: unknown } | null;
      error: unknown;
    } | null
  >;
}

/** Shared by both AI endpoints. Only model failures enter the refund path.
 * Repeating the existing service-only commit RPC is an atomic status check
 * and, if still reserved, a commit. Never release after attempting commitment:
 * an error/timeout may conceal a successful database transaction.
 */
export async function deliverReservedOperation<T>(
  admin: ReservationClient,
  reservation: UsageReservation,
  request: Request,
  operation: () => Promise<T>,
  content: (value: T) => Record<string, unknown>,
  failureCode: string,
  log: (status: number, category: string, value?: T) => void,
): Promise<Response> {
  let guarded: ReservedOperation<T>;
  try {
    guarded = await performReservedOperation(reservation, request, operation);
  } catch {
    // No commit was attempted and no output was delivered. SQL release only
    // refunds reserved rows; a failed release is recovered by stale cleanup.
    let refunded = false;
    try {
      const released = await admin.rpc("release_user_reservation", {
        p_reservation_id: reservation.reservation_id,
      });
      refunded = !released?.error && released?.data?.outcome === "released";
    } catch { /* Leave reserved for expiration cleanup. */ }
    log(
      500,
      refunded
        ? "generation_failed_refunded"
        : "generation_failed_refund_pending",
    );
    return errorJson(
      500,
      failureCode,
      "Generation failed. Refresh usage before starting a new request.",
      {},
      request,
    );
  }
  if (!guarded.performed) {
    log(
      guarded.response.status,
      reservation.outcome === "duplicate"
        ? "duplicate_request"
        : "invalid_reservation",
    );
    return guarded.response;
  }

  // Two attempts on the SAME reservation, never another reservation or model
  // call. A lost first acknowledgment can therefore recover the live output.
  for (let attempt = 0; attempt < 2; attempt++) {
    let commit;
    try {
      commit = await admin.rpc("commit_user_reservation", {
        p_reservation_id: reservation.reservation_id,
      });
    } catch { /* Ambiguous transport failure: re-confirm, never refund. */ }
    if (commit && !commit.error && commit.data?.outcome === "committed") {
      // Serialization/logging failures must also never enter the refund path.
      const response = json(200, {
        ...content(guarded.value),
        usage: commit.data.usage,
      }, request);
      log(200, "committed", guarded.value);
      return response;
    }
  }
  // A separate read can succeed even when the mutation acknowledgments fail.
  // Only terminal committed is proof; reserved may race an in-flight commit.
  try {
    const state = await admin.rpc("get_user_reservation_status", {
      p_reservation_id: reservation.reservation_id,
    });
    if (state && !state.error && state.data?.status === "committed") {
      const response = json(200, {
        ...content(guarded.value),
        usage: state.data.usage,
      }, request);
      log(200, "commit_confirmed_by_read", guarded.value);
      return response;
    }
  } catch { /* No confirmed commitment: withhold output and preserve state. */ }
  log(503, "commit_unconfirmed");
  return errorJson(
    503,
    "ACCOUNTING_UNCONFIRMED",
    "Output could not be delivered because accounting could not be confirmed. Retry only with the same request ID; refresh usage before choosing to start a new request.",
    {},
    request,
  );
}
