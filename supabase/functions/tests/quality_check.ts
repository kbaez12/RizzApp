// Response-quality harness. NOT an automated test — it calls the real
// generate endpoint (which spends OpenAI calls) and prints results for
// manual judgement.
//
// Run:
//   INTEGRATION=true SUPABASE_URL=http://127.0.0.1:54321 \
//   PUBLISHABLE_KEY=<local publishable key> \
//   deno run --allow-net --allow-env supabase/functions/tests/quality_check.ts
//
// Optional: --case="dry reply"   to run a single scenario.
//           --goal=flirty        to override the goal.
//
// For each result judge: does it sound human? does it sound like the user?
// are the three routes actually different strategies? anything cringe? does
// it invent details? would a real person send it?
//
// Uses the Plus fixture installation so the free tier is not consumed.

const BASE = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const KEY = Deno.env.get("PUBLISHABLE_KEY") ?? "";
const PLUS_INSTALLATION = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

interface Scenario {
  name: string;
  goal: string;
  text: string;
  watchFor: string;
}

const SCENARIOS: Scenario[] = [
  {
    name: "normal flirting",
    goal: "flirty",
    watchFor: "Confident without being explicit. Should not over-escalate.",
    text: `them: ok that concert story actually made me laugh out loud
me: i have better ones but i ration them
them: oh so you're withholding content from me now 😭`,
  },
  {
    name: "dry reply",
    goal: "keep_it_going",
    watchFor: "Must not chase or ask an interview question. Low-effort match.",
    text: `me: how was the wedding? did anyone embarrass themselves
them: it was good
me: that's it? no drama at all
them: nah it was chill`,
  },
  {
    name: "playful banter",
    goal: "playful",
    watchFor: "Should keep the bit going, not restart the topic.",
    text: `them: i cannot believe you put pineapple on pizza
me: i contain multitudes
them: you contain crimes
me: bold words from someone who dips fries in a milkshake
them: that's CULTURE`,
  },
  {
    name: "early dating app match",
    goal: "keep_it_going",
    watchFor: "Little history. Should not invent shared context.",
    text: `them: hey! your dog is very cute, what's his name
me: thanks haha his name is banjo. he's a menace though`,
  },
  {
    name: "awkward recovery",
    goal: "recover_this",
    watchFor: "No long apology, no wounded tone. Light reset.",
    text: `me: so are we doing drinks friday or are you gonna leave me on read again
them: wow
me: that came out worse than i meant
them: yeah it kinda did lol`,
  },
  {
    name: "very short lowercase user",
    goal: "flirty",
    watchFor: "Reply must be tiny, lowercase, no punctuation, no emoji.",
    text: `them: What are you up to this weekend? I might go to that new place downtown.
me: idk yet
them: You should come with me, it's supposed to be really good
me: maybe`,
  },
  {
    name: "emoji-heavy user",
    goal: "playful",
    watchFor: "Should use emoji (1-2), matching their energy, not zero.",
    text: `them: i just got back from the gym and i'm dying 😭
me: gym?? in this economy?? 😭😭 i could never
them: you say that but i've seen your protein shake collection 🤨
me: that's for CULINARY purposes 😌`,
  },
  {
    name: "no-emoji user",
    goal: "flirty",
    watchFor: "Must contain zero emoji. Proper-ish casing.",
    text: `them: I had a really good time last night.
me: Same. That place was better than I expected.
them: We should do it again sometime.`,
  },
  {
    name: "obvious rejection",
    goal: "make_a_move",
    watchFor:
      "Must NOT push for a date. Graceful low-key exit is the correct answer even though the goal says make a move.",
    text: `me: any interest in grabbing dinner this week?
them: hey, you seem really nice but i think i'm gonna pass. just not feeling a spark
me: all good, appreciate you saying so`,
  },
  {
    name: "almost no context",
    goal: "funny",
    watchFor: "Must work with nothing. Should not fabricate details.",
    text: `them: hey`,
  },
];

async function run(scenario: Scenario, goalOverride?: string) {
  const goal = goalOverride ?? scenario.goal;
  const started = Date.now();
  const response = await fetch(`${BASE}/functions/v1/generate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: KEY,
      "x-installation-id": PLUS_INSTALLATION,
    },
    body: JSON.stringify({
      input: { kind: "text", text: scenario.text },
      goal,
      refinement: null,
      previous_responses: null,
      request_id: crypto.randomUUID(),
    }),
  });

  console.log("\n" + "=".repeat(70));
  console.log(`CASE: ${scenario.name}   GOAL: ${goal}   (${Date.now() - started}ms)`);
  console.log(`WATCH FOR: ${scenario.watchFor}`);
  console.log("-".repeat(70));

  if (!response.ok) {
    console.log(`FAILED ${response.status}: ${await response.text()}`);
    return;
  }
  const body = await response.json();
  for (const reply of body.responses) {
    console.log(`[${reply.label}] ${reply.text}`);
  }
  console.log(`usage: ${body.usage.remaining}/${body.usage.limit} (${body.usage.tier})`);
}

if (Deno.env.get("INTEGRATION") !== "true") {
  console.log("Set INTEGRATION=true (and PUBLISHABLE_KEY) to run. This spends OpenAI calls.");
} else {
  const args = Deno.args.join(" ");
  const caseFilter = /--case="?([^"]+)"?/.exec(args)?.[1];
  const goalOverride = /--goal=(\w+)/.exec(args)?.[1];
  const selected = caseFilter
    ? SCENARIOS.filter((s) => s.name.includes(caseFilter))
    : SCENARIOS;

  for (const scenario of selected) {
    await run(scenario, goalOverride);
  }
  console.log("\nDone. Judge each case by hand; iterate on _shared/prompt.ts.");
}
