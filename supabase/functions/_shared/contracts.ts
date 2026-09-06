// Request contract validation shared by edge functions.
// Mirrors the Swift client contract (GenerationRequest / GenerationResult).

export const SUPPORTED_GOALS = [
  "playful",
  "flirty",
  "funny",
  "keep_it_going",
  "make_a_move",
  "recover_this",
] as const;

export const SUPPORTED_REFINEMENTS = [
  "shorter",
  "bolder",
  "more_like_me",
  "less_cringe",
] as const;

export const MAX_TEXT_LENGTH = 4_000;
// Client caps processed screenshots at 3 MB binary; base64 is ~4/3 of that.
export const MAX_IMAGE_BASE64_LENGTH = 4_200_000;
export const MAX_BODY_BYTES = 5_000_000;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

export interface GenerationRequestBody {
  input?: {
    kind?: string;
    text?: string;
    image_base64?: string;
  };
  goal?: string;
  refinement?: string | null;
  previous_responses?: unknown;
  /** Client-generated idempotency key (UUID). Same logical request retried
   * MUST reuse the same id so quota is never charged twice. */
  request_id?: string;
}

/** Server-side action classification — the charge category is derived from
 * the request shape, never from client instructions. Initial generation and
 * "Generate 3 More" are full generations; any refinement field makes it a
 * refinement. */
export function classifyAction(
  body: GenerationRequestBody,
): "generation" | "refinement" {
  return body.refinement ? "refinement" : "generation";
}

export type ValidationResult =
  | { ok: true }
  | { ok: false; message: string };

export function isValidInstallationId(value: string | null): boolean {
  return value !== null && UUID_PATTERN.test(value);
}

export function validateGenerationRequest(body: unknown): ValidationResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, message: "Body must be a JSON object." };
  }
  const request = body as GenerationRequestBody;

  const input = request.input;
  if (typeof input !== "object" || input === null) {
    return { ok: false, message: "Missing input." };
  }

  if (input.kind === "text") {
    const text = input.text;
    if (typeof text !== "string" || text.trim().length === 0) {
      return { ok: false, message: "Text input is empty." };
    }
    if (text.length > MAX_TEXT_LENGTH) {
      return { ok: false, message: "Text input is too long." };
    }
  } else if (input.kind === "image") {
    const image = input.image_base64;
    if (typeof image !== "string" || image.length === 0) {
      return { ok: false, message: "Missing image data." };
    }
    if (image.length > MAX_IMAGE_BASE64_LENGTH) {
      return { ok: false, message: "Image is too large." };
    }
    if (!BASE64_PATTERN.test(image)) {
      return { ok: false, message: "Image data is malformed." };
    }
  } else {
    return { ok: false, message: "input.kind must be 'text' or 'image'." };
  }

  if (
    typeof request.goal !== "string" ||
    !(SUPPORTED_GOALS as readonly string[]).includes(request.goal)
  ) {
    return { ok: false, message: "Unsupported goal." };
  }

  if (
    request.refinement !== undefined &&
    request.refinement !== null &&
    !(SUPPORTED_REFINEMENTS as readonly string[]).includes(request.refinement)
  ) {
    return { ok: false, message: "Unsupported refinement." };
  }

  if (
    typeof request.request_id !== "string" ||
    !UUID_PATTERN.test(request.request_id)
  ) {
    return { ok: false, message: "Missing or invalid request_id." };
  }

  return { ok: true };
}
