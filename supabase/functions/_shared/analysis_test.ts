// deno test supabase/functions/_shared/analysis_test.ts

import { assertEquals } from "jsr:@std/assert";
import { normalize } from "./analysis.ts";
import { validateAnalysisRequest } from "./contracts.ts";

const REQUEST_ID = "0b8f7d9e-6a3c-4e2b-9c1d-5f4a3b2c1d0e";

Deno.test("analysis request needs input and request_id, no goal", () => {
  assertEquals(
    validateAnalysisRequest({
      input: { kind: "text", text: "them: hey" },
      request_id: REQUEST_ID,
    }).ok,
    true,
  );
  assertEquals(
    validateAnalysisRequest({ input: { kind: "text", text: "hey" } }).ok,
    false,
  );
  assertEquals(validateAnalysisRequest({ request_id: REQUEST_ID }).ok, false);
});

Deno.test("normalize clamps interest and trims flags", () => {
  const result = normalize({
    your_interest: 140,
    their_interest: -5,
    vibe: "  fine  ",
    green_flags: ["a", "b", "c", "d", ""],
    red_flags: "not an array",
    next_move: "sure — thursday",
  });
  assertEquals(result.your_interest, 100);
  assertEquals(result.their_interest, 0);
  assertEquals(result.vibe, "fine");
  assertEquals(result.green_flags, ["a", "b", "c"]);
  assertEquals(result.red_flags, []);
  assertEquals(result.next_move.includes("—"), false);
});
