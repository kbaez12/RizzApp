// Turns a validated request into three replies: one OpenAI call, Cringe
// Guard validation, at most one corrective retry, then mechanical cleanup.

import type { GenerationRequestBody } from "./contracts.ts";
import { checkReplies, sanitize } from "./cringe_guard.ts";
import { generateStructured, OpenAIError } from "./openai.ts";
import {
  RESPONSE_SCHEMA,
  ROUTE_LABELS,
  retryNote,
  systemPrompt,
  userInstruction,
} from "./prompt.ts";

/** Per-attempt timeout. Two attempts stay comfortably inside the client's
 * 60s budget, leaving room to refund and respond. */
const ATTEMPT_TIMEOUT_MS = 25_000;

export interface ProducedReplies {
  responses: Array<{ type: string; label: string; text: string }>;
  retried: boolean;
  /** Operational metrics only — safe to log. */
  inputTokens: number | null;
  outputTokens: number | null;
  /** Problems remaining after the retry, for logging (counts only). */
  remainingProblems: number;
}

export async function produceReplies(
  body: GenerationRequestBody,
): Promise<ProducedReplies> {
  const system = systemPrompt();
  const baseInstruction = userInstruction(body);
  const image = body.input?.kind === "image" && body.input.image_base64
    ? { base64: body.input.image_base64 }
    : undefined;

  const attempt = async (instruction: string) =>
    await generateStructured({
      system,
      instruction,
      image,
      schema: RESPONSE_SCHEMA,
      schemaName: "rizz_replies",
      signal: AbortSignal.timeout(ATTEMPT_TIMEOUT_MS),
    });

  let result = await attempt(baseInstruction);
  let replies = routeTexts(result.parsed);
  let { problems } = checkReplies(replies);
  let retried = false;

  // Single retry: covers both a failed structured/validation outcome and a
  // transient API hiccup (the throw from the first attempt propagates only
  // if it is non-retryable — see the catch in the caller).
  if (problems.length > 0) {
    retried = true;
    try {
      result = await attempt(`${baseInstruction}\n\n${retryNote(problems)}`);
      const retryReplies = routeTexts(result.parsed);
      const retryCheck = checkReplies(retryReplies);
      // Keep the better attempt.
      if (retryCheck.problems.length <= problems.length) {
        replies = retryReplies;
        problems = retryCheck.problems;
      }
    } catch (error) {
      // Retry failed outright — ship the first attempt if it was usable at
      // all, otherwise surface the failure so the caller refunds.
      if (!hasUsableText(replies)) throw error;
    }
  }

  if (!hasUsableText(replies)) {
    throw new OpenAIError("Generated replies were unusable.", false);
  }

  return {
    responses: (["natural", "bold", "advance"] as const).map((route) => ({
      type: route,
      label: ROUTE_LABELS[route],
      text: sanitize(replies[route] ?? ""),
    })),
    retried,
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
    remainingProblems: problems.length,
  };
}

function routeTexts(parsed: Record<string, unknown>): Record<string, string> {
  return {
    natural: String(parsed.natural ?? ""),
    bold: String(parsed.bold ?? ""),
    advance: String(parsed.advance ?? ""),
  };
}

function hasUsableText(replies: Record<string, string>): boolean {
  return ["natural", "bold", "advance"].every(
    (route) => (replies[route] ?? "").trim().length > 0,
  );
}
