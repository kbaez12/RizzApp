// deno test supabase/functions/_shared/cringe_guard_test.ts

import { assert, assertEquals } from "jsr:@std/assert";
import { checkReplies, sanitize } from "./cringe_guard.ts";

const good = {
  natural: "gotta keep some mystery",
  bold: "you're very invested for someone who hasn't asked me out yet",
  advance: "next story's in person. thursday?",
};

Deno.test("clean replies pass", () => {
  assertEquals(checkReplies(good).problems.length, 0);
});

Deno.test("assistant-sounding reply is flagged", () => {
  const { problems } = checkReplies({
    ...good,
    natural: "Here are a few ways you could respond to that message!",
  });
  assert(problems.some((p) => p.includes("assistant-written")));
});

Deno.test("pickup line is flagged", () => {
  const { problems } = checkReplies({ ...good, bold: "hey beautiful, did it hurt?" });
  assert(problems.length > 0);
});

Deno.test("interview question is flagged", () => {
  const { problems } = checkReplies({ ...good, natural: "so what do you do for fun?" });
  assert(problems.some((p) => p.includes("interview")));
});

Deno.test("overlong reply is flagged", () => {
  const { problems } = checkReplies({ ...good, natural: "a".repeat(400) });
  assert(problems.some((p) => p.includes("too long")));
});

Deno.test("emoji spam is flagged", () => {
  const { problems } = checkReplies({ ...good, bold: "lol 😭😭😭😭 stop 🤣" });
  assert(problems.some((p) => p.includes("emoji")));
});

Deno.test("em dash is flagged", () => {
  const { problems } = checkReplies({ ...good, natural: "sure — whenever you want" });
  assert(problems.length > 0);
});

Deno.test("identical routes are flagged", () => {
  const { problems } = checkReplies({ ...good, bold: good.natural });
  assert(problems.some((p) => p.includes("identical")));
});

Deno.test("empty reply is flagged", () => {
  const { problems } = checkReplies({ ...good, advance: "  " });
  assert(problems.some((p) => p.includes("empty")));
});

Deno.test("sanitize trims length and surplus emoji", () => {
  const cleaned = sanitize("wow 😭😭😭😭 ok");
  assertEquals((cleaned.match(/\p{Extended_Pictographic}/gu) ?? []).length, 2);

  const long = sanitize("word ".repeat(100));
  assert(long.length <= 220);
});

Deno.test("sanitize replaces em dash and semicolon", () => {
  const cleaned = sanitize("sure — ok; fine");
  assert(!cleaned.includes("—"));
  assert(!cleaned.includes(";"));
});
