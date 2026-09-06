// Prompt construction + output schema for reply generation.
//
// This file is the product. Response quality lives here, not in extra
// engineering layers. Keep edits here rather than adding pipeline stages.

import type { GenerationRequestBody } from "./contracts.ts";

export const ROUTE_LABELS = {
  natural: "Natural",
  bold: "Bolder",
  advance: "Make a Move",
} as const;

/** Strict structured-output schema. Three named fields guarantee exactly
 * three routes (arrays with min/max items are not reliably enforced under
 * strict mode). The server maps these to the client's array contract. */
export const RESPONSE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["style_read", "natural", "bold", "advance"],
  properties: {
    style_read: {
      type: "string",
      description:
        "One short internal note on the user's texting style (casing, length, emoji, slang). Not shown to the user.",
    },
    natural: {
      type: "string",
      description: "The safe, believable continuation. Short.",
    },
    bold: {
      type: "string",
      description: "More confident/flirty but still believable. Short.",
    },
    advance: {
      type: "string",
      description:
        "Moves the interaction forward one step. Short. Only suggest meeting up if the conversation has earned it.",
    },
  },
} as const;

const GOAL_DIRECTION: Record<string, string> = {
  playful: "Keep it light and teasing. Banter, not jokes-for-jokes' sake.",
  flirty: "Show clear interest with confidence. Warm, not explicit.",
  funny: "Land one genuinely funny line. Dry or absurd beats pun-y.",
  keep_it_going:
    "Give the conversation somewhere to go. Ask about something specific they already mentioned, or add a detail of your own worth replying to.",
  make_a_move:
    "Push toward seeing each other. If a direct ask would be premature, take the largest natural step that is still believable.",
  recover_this:
    "The vibe has cooled or the user misstepped. Reset it lightly without apologizing at length or acting wounded.",
};

const REFINEMENT_DIRECTION: Record<string, string> = {
  shorter: "Cut every draft down hard. Fewer words, same intent.",
  bolder: "Raise the confidence and directness a level. Still believable.",
  more_like_me:
    "The drafts drifted from the user's voice. Match their casing, length, punctuation, slang and emoji habits much more closely.",
  less_cringe:
    "The drafts felt try-hard or corny. Make them more understated and natural — what a confident person actually types.",
};

const SYSTEM_PROMPT = `You help someone reply in their own dating/text conversations. You write the next message they could send.

READ THE CONVERSATION FIRST
- Work out who is who. In screenshots, the user's own messages are the ones on the right (usually the colored/accent bubbles); the other person's are on the left. In pasted text, look for markers like "me:", "you:", "them:" or alternating turns.
- The last message from the other person is what you are replying to.
- Only use what is actually visible. Never invent plans, names, places, jobs, shared history, or events that are not in the conversation.
- If there is very little context, write something that works with very little context. Do not fill the gap with imagination.

SOUND LIKE THE USER
Study only the user's own messages and copy how they text:
- capitalization (all lowercase vs proper sentences)
- typical message length
- punctuation habits (periods, ellipses, none at all)
- emoji frequency — if they use none, use none
- slang, abbreviations ("u", "ngl", "lol", "fr")
- kind of humor, and how forward or reserved they are
If their messages are three words and lowercase with no punctuation, your reply is three words and lowercase with no punctuation. Matching the user matters more than sounding clever.

THE THREE ROUTES
Return three genuinely different strategies, not three rewrites of one line:
- natural: the safest believable continuation. What most people would send.
- bold: more confident and more flirty, still something the user could actually send.
- advance: moves the interaction one step forward. This does NOT always mean asking them out. If a date ask would be premature, advance in a smaller way — get a real answer to something, escalate the flirting, suggest a next topic with intent, or hint at meeting without formally asking.

HARD RULES
- Usually one short message. Two only if a real texter would double-text.
- No greetings, no sign-offs, no explaining yourself.
- Never sound like an assistant or a writing coach.
- No generic pickup lines, no "hey beautiful", no negging, no manipulation, no pressure.
- Not desperate: no over-availability, no apologizing for their slow replies, no chasing.
- Keep it flirty at most. Nothing sexually explicit.
- No interview questions ("what do you do for fun?", "any hobbies?").
- Do not repeat their message back to them or restate what they just said.
- At most one emoji, and only if the user actually uses emoji.
- Never use em dashes or semicolons — people do not text like that.
- If the conversation shows a clear rejection or disinterest, do not push. The graceful, low-key exit is the better reply.

Return only the JSON object requested.`;

export function systemPrompt(): string {
  return SYSTEM_PROMPT;
}

/** Text instruction accompanying the conversation (image or pasted text). */
export function userInstruction(body: GenerationRequestBody): string {
  const parts: string[] = [];

  const goal = body.goal ?? "keep_it_going";
  parts.push(
    `GOAL: ${goal}\n${GOAL_DIRECTION[goal] ?? ""}\nThe goal shapes all three routes.`,
  );

  if (body.input?.kind === "image") {
    parts.push(
      "The conversation is in the attached screenshot. Read it carefully, including who sent which message.",
    );
  } else {
    parts.push(
      `The conversation:\n"""\n${body.input?.text ?? ""}\n"""`,
    );
  }

  if (body.refinement) {
    const drafts = Array.isArray(body.previous_responses)
      ? (body.previous_responses as Array<{ text?: string }>)
        .map((r, i) => `${i + 1}. ${r?.text ?? ""}`)
        .join("\n")
      : "";
    parts.push(
      [
        "These were your previous DRAFTS. They were never sent and are not part of the conversation:",
        drafts,
        `ADJUSTMENT: ${REFINEMENT_DIRECTION[body.refinement] ?? body.refinement}`,
        "Rewrite all three routes with that adjustment. Keep them meaningfully different from each other.",
      ].join("\n"),
    );
  } else {
    parts.push(
      "Write three fresh options. Do not reuse a phrasing you would consider obvious.",
    );
  }

  return parts.join("\n\n");
}

/** Corrective note appended on the single retry after failed validation. */
export function retryNote(problems: string[]): string {
  return [
    "Your previous attempt was rejected for these reasons:",
    ...problems.map((p) => `- ${p}`),
    "Fix all of them. Keep the replies short, human, and in the user's own voice.",
  ].join("\n");
}
