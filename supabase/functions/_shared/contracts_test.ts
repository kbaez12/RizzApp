// Contract/validation tests. Run with:
//   deno test supabase/functions/_shared/contracts_test.ts

import { assertEquals } from "jsr:@std/assert";
import {
  MAX_IMAGE_BASE64_LENGTH,
  MAX_TEXT_LENGTH,
  isValidInstallationId,
  validateGenerationRequest,
} from "./contracts.ts";
import { CANNED_REFINED, CANNED_RESPONSES } from "./canned.ts";

const validText = {
  input: { kind: "text", text: "them: hey lol\nme: hey" },
  goal: "flirty",
  refinement: null,
  previous_responses: null,
};

const validImage = {
  input: { kind: "image", image_base64: "aGVsbG8gd29ybGQ=" },
  goal: "playful",
};

Deno.test("valid text request passes", () => {
  assertEquals(validateGenerationRequest(validText).ok, true);
});

Deno.test("valid image request passes", () => {
  assertEquals(validateGenerationRequest(validImage).ok, true);
});

Deno.test("unsupported goal rejected", () => {
  const result = validateGenerationRequest({ ...validText, goal: "chaotic" });
  assertEquals(result.ok, false);
});

Deno.test("missing input rejected", () => {
  assertEquals(validateGenerationRequest({ goal: "flirty" }).ok, false);
});

Deno.test("empty text rejected", () => {
  const result = validateGenerationRequest({
    ...validText,
    input: { kind: "text", text: "   " },
  });
  assertEquals(result.ok, false);
});

Deno.test("oversized text rejected", () => {
  const result = validateGenerationRequest({
    ...validText,
    input: { kind: "text", text: "x".repeat(MAX_TEXT_LENGTH + 1) },
  });
  assertEquals(result.ok, false);
});

Deno.test("malformed base64 rejected", () => {
  const result = validateGenerationRequest({
    ...validImage,
    input: { kind: "image", image_base64: "!!! not base64 !!!" },
  });
  assertEquals(result.ok, false);
});

Deno.test("oversized image rejected", () => {
  const result = validateGenerationRequest({
    ...validImage,
    input: { kind: "image", image_base64: "A".repeat(MAX_IMAGE_BASE64_LENGTH + 4) },
  });
  assertEquals(result.ok, false);
});

Deno.test("unsupported refinement rejected", () => {
  const result = validateGenerationRequest({
    ...validText,
    refinement: "sassier",
  });
  assertEquals(result.ok, false);
});

Deno.test("installation id validation", () => {
  assertEquals(isValidInstallationId(crypto.randomUUID()), true);
  assertEquals(isValidInstallationId(null), false);
  assertEquals(isValidInstallationId("not-a-uuid"), false);
});

Deno.test("canned response schema is complete", () => {
  assertEquals(CANNED_RESPONSES.length, 3);
  assertEquals(CANNED_RESPONSES.map((r) => r.type), [
    "natural",
    "bold",
    "advance",
  ]);
  for (const set of Object.values(CANNED_REFINED)) {
    assertEquals(set.length, 3);
    for (const response of set) {
      assertEquals(typeof response.label, "string");
      assertEquals(typeof response.text, "string");
      assertEquals(response.text.length > 0, true);
    }
  }
});
