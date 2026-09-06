// Cringe Guard: mechanical checks on generated replies.
//
// Deliberately simple — a second AI moderation pass is not worth the cost
// or latency for an MVP. The prompt does the heavy lifting; this catches
// the recognizable failure modes and drives the single retry.

const MAX_CHARS = 220;
const MAX_EMOJI = 2;

// Phrases that immediately read as assistant-written.
const AI_TELLS = [
  "as an ai",
  "i'm an ai",
  "here are",
  "here's a",
  "option 1",
  "certainly",
  "i'd be happy to",
  "let me know if",
  "feel free to",
  "hope this helps",
  "great question",
  "that sounds like",
  "it's important to",
];

// Generic opener/pickup-line territory.
const PICKUP_LINES = [
  "hey beautiful",
  "hey gorgeous",
  "hey pretty",
  "must be a sign",
  "did it hurt",
  "on a scale of",
  "rate me",
  "you had me at",
  "is it hot in here",
];

// Interview-style filler questions.
const INTERVIEW_QUESTIONS = [
  "what do you do for fun",
  "any hobbies",
  "what do you do for work",
  "how was your day",
  "what are you looking for",
  "tell me about yourself",
  "what's your favorite",
];

const EMOJI_PATTERN = /\p{Extended_Pictographic}/gu;

export interface GuardOutcome {
  problems: string[];
}

/** Returns human-readable problems (empty = acceptable). Used for the retry
 * note; never shown to users. */
export function checkReplies(replies: Record<string, string>): GuardOutcome {
  const problems: string[] = [];
  const entries = Object.entries(replies);

  for (const [route, raw] of entries) {
    const text = (raw ?? "").trim();
    const lower = text.toLowerCase();

    if (text.length === 0) {
      problems.push(`${route}: empty reply.`);
      continue;
    }
    if (text.length > MAX_CHARS) {
      problems.push(`${route}: too long (${text.length} chars). Keep it to one short message.`);
    }
    if (text.split("\n\n").length > 1) {
      problems.push(`${route}: written as paragraphs. Send one short message.`);
    }
    const emojiCount = (text.match(EMOJI_PATTERN) ?? []).length;
    if (emojiCount > MAX_EMOJI) {
      problems.push(`${route}: too many emoji (${emojiCount}).`);
    }
    if (text.includes("—") || text.includes(";")) {
      problems.push(`${route}: uses em dash or semicolon. People do not text like that.`);
    }
    if (AI_TELLS.some((tell) => lower.includes(tell))) {
      problems.push(`${route}: sounds assistant-written.`);
    }
    if (PICKUP_LINES.some((line) => lower.includes(line))) {
      problems.push(`${route}: generic pickup line.`);
    }
    if (INTERVIEW_QUESTIONS.some((question) => lower.includes(question))) {
      problems.push(`${route}: boring interview-style question.`);
    }
    if (/\bi'm sorry\b|\bsorry for\b/.test(lower) && route !== "natural") {
      problems.push(`${route}: apologetic. Do not sound like you are chasing.`);
    }
  }

  // Three routes must be actually different strategies.
  const texts = entries.map(([, t]) => (t ?? "").trim().toLowerCase());
  if (new Set(texts).size < texts.length) {
    problems.push("Two routes are identical. They must be different strategies.");
  }

  return { problems };
}

/** Last-resort tidy-up applied after the retry so a borderline result still
 * ships rather than charging the user nothing and failing. Trims runaway
 * length and strips surplus emoji; does not attempt to rewrite tone. */
export function sanitize(text: string): string {
  let output = text.trim().replace(/—/g, "-").replace(/;/g, ",");

  const emoji = output.match(EMOJI_PATTERN) ?? [];
  if (emoji.length > MAX_EMOJI) {
    let seen = 0;
    output = output
      .replace(EMOJI_PATTERN, (match) => (++seen <= MAX_EMOJI ? match : ""))
      .trim();
  }

  if (output.length > MAX_CHARS) {
    const cut = output.slice(0, MAX_CHARS);
    const lastBreak = Math.max(cut.lastIndexOf(". "), cut.lastIndexOf(" "));
    output = (lastBreak > 60 ? cut.slice(0, lastBreak) : cut).trim();
  }
  return output;
}
