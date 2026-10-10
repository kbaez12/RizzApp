import { errorJson } from "./responses.ts";

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
 * persisted. A stable 409 tells the client to begin a new logical request.
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
        "This request has already been processed. Start a new request.",
        { usage: reservation.usage },
        request,
      ),
    };
  }

  return { performed: true, value: await operation() };
}
