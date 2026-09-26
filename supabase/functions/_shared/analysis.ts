// Chat analysis: an honest read of a conversation (interest levels, vibe,
// flags, next move). One OpenAI call, one retry on failure, then clamping.

import type { GenerationRequestBody } from "./contracts.ts";
import { sanitize } from "./cringe_guard.ts";
import { generateStructured, type OpenAIResult } from "./openai.ts";

const ATTEMPT_TIMEOUT_MS = 25_000;
const MAX_FLAGS = 3;
const MAX_FLAG_CHARS = 120;
const MAX_VIBE_CHARS = 280;

export const ANALYSIS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: [
    "your_interest",
    "their_interest",
    "vibe",
    "green_flags",
    "red_flags",
    "next_move",
  ],
  properties: {
    your_interest: {
      type: "integer",
      description: "0-100 estimate of how interested the user seems.",
    },
    their_interest: {
      type: "integer",
      description: "0-100 estimate of how interested the other person seems.",
    },
    vibe: { type: "string", description: "One or two plain sentences." },
    green_flags: { type: "array", items: { type: "string" } },
    red_flags: { type: "array", items: { type: "string" } },
    next_move: {
      type: "string",
      description: "One short message the user could send next, in their own style.",
    },
  },
} as const;

const SYSTEM_PROMPT = `You read someone's dating/text conversation and give them an honest, useful read on it.

WHO IS WHO
- In screenshots, the user's messages are on the right (usually colored bubbles); the other person's are on the left. In pasted text look for "me:", "you:", "them:".

HOW TO JUDGE INTEREST (0-100)
Base it only on visible signals: reply length and effort, questions asked back, who initiates, enthusiasm, emoji and warmth, whether plans get picked up or dodged. Short, flat, one-word replies with no questions back mean low interest. Be honest, not flattering. If there is very little conversation, stay near the middle and say the read is limited.

FLAGS
- green_flags and red_flags: at most 3 each, each one short and tied to something actually in the messages. An empty list is fine.
- Only comment on texting behavior. No diagnoses, no attachment-style labels, no guesses about their life.
- Never invent messages, names, plans, or history.

VIBE
One or two plain sentences, like a perceptive friend would say it. No hype.

NEXT MOVE
One short message the user could send now, written in THEIR texting style (casing, length, punctuation, emoji habits). If the other person has clearly lost interest or said no, the next move is a graceful low-key reply or letting it go — say so plainly, do not push.

Return only the JSON object requested.`;

export interface ChatAnalysis {
  your_interest: number;
  their_interest: number;
  vibe: string;
  green_flags: string[];
  red_flags: string[];
  next_move: string;
}

export interface ProducedAnalysis {
  analysis: ChatAnalysis;
  inputTokens: number | null;
  outputTokens: number | null;
}

export async function produceAnalysis(
  body: GenerationRequestBody,
): Promise<ProducedAnalysis> {
  const instruction = body.input?.kind === "image"
    ? "Analyze the conversation in the attached screenshot."
    : `Analyze this conversation:\n"""\n${body.input?.text ?? ""}\n"""`;
  const image = body.input?.kind === "image" && body.input.image_base64
    ? { base64: body.input.image_base64 }
    : undefined;

  const attempt = async () =>
    await generateStructured({
      system: SYSTEM_PROMPT,
      instruction,
      image,
      schema: ANALYSIS_SCHEMA,
      schemaName: "chat_analysis",
      signal: AbortSignal.timeout(ATTEMPT_TIMEOUT_MS),
    });

  let result: OpenAIResult;
  try {
    result = await attempt();
  } catch {
    result = await attempt();
  }

  return {
    analysis: normalize(result.parsed),
    inputTokens: result.inputTokens,
    outputTokens: result.outputTokens,
  };
}

/** Clamps and trims model output so the client always gets sane values. */
export function normalize(parsed: Record<string, unknown>): ChatAnalysis {
  const percent = (value: unknown) =>
    Math.max(0, Math.min(100, Math.round(Number(value) || 0)));
  const flags = (value: unknown) =>
    (Array.isArray(value) ? value : [])
      .map((flag) => String(flag).trim())
      .filter((flag) => flag.length > 0)
      .slice(0, MAX_FLAGS)
      .map((flag) => flag.slice(0, MAX_FLAG_CHARS));

  return {
    your_interest: percent(parsed.your_interest),
    their_interest: percent(parsed.their_interest),
    vibe: String(parsed.vibe ?? "").trim().slice(0, MAX_VIBE_CHARS),
    green_flags: flags(parsed.green_flags),
    red_flags: flags(parsed.red_flags),
    next_move: sanitize(String(parsed.next_move ?? "")),
  };
}

/** Dev-only fixture for the "canned" debug scenario. */
export const CANNED_ANALYSIS: ChatAnalysis = {
  your_interest: 64,
  their_interest: 71,
  vibe: "Easy back-and-forth and they're teasing you, which is a good sign. Keep the energy light.",
  green_flags: ["They keep the bit going", "Quick, playful replies"],
  red_flags: [],
  next_move: "fine. one more story but it'll cost you a coffee",
};
