import { assertEquals } from "jsr:@std/assert";
import { generateStructured } from "./openai.ts";

Deno.test("Responses request keeps privacy, image, schema, and cost controls", async () => {
  const originalFetch = globalThis.fetch;
  const originalValues = {
    key: Deno.env.get("OPENAI_API_KEY"),
    model: Deno.env.get("OPENAI_MODEL"),
    tokens: Deno.env.get("OPENAI_MAX_OUTPUT_TOKENS"),
    effort: Deno.env.get("OPENAI_REASONING_EFFORT"),
  };
  let sentBody: Record<string, unknown> | undefined;

  try {
    Deno.env.set("OPENAI_API_KEY", "test-only");
    Deno.env.set("OPENAI_MODEL", "gpt-5.6-luna");
    Deno.env.set("OPENAI_MAX_OUTPUT_TOKENS", "500");
    Deno.env.set("OPENAI_REASONING_EFFORT", "low");
    globalThis.fetch = (_input, init) => {
      sentBody = JSON.parse(String(init?.body));
      return Promise.resolve(
        new Response(
          JSON.stringify({
            output_text: JSON.stringify({ responses: [] }),
            usage: { input_tokens: 10, output_tokens: 5 },
          }),
          { status: 200 },
        ),
      );
    };

    const result = await generateStructured({
      system: "system",
      instruction: "instruction",
      image: { base64: "aGVsbG8=" },
      schemaName: "test_schema",
      schema: {
        type: "object",
        properties: { responses: { type: "array" } },
        required: ["responses"],
        additionalProperties: false,
      },
    });

    assertEquals(result.parsed, { responses: [] });
    assertEquals(sentBody?.model, "gpt-5.6-luna");
    assertEquals(sentBody?.store, false);
    assertEquals(sentBody?.max_output_tokens, 500);
    assertEquals(sentBody?.reasoning, { effort: "low" });

    const input = sentBody?.input as Array<Record<string, unknown>>;
    const userContent = input[1].content as Array<Record<string, unknown>>;
    assertEquals(userContent[1], {
      type: "input_image",
      image_url: "data:image/jpeg;base64,aGVsbG8=",
    });

    const text = sentBody?.text as {
      format: { type: string; strict: boolean; name: string };
    };
    assertEquals(text.format.type, "json_schema");
    assertEquals(text.format.strict, true);
    assertEquals(text.format.name, "test_schema");
  } finally {
    globalThis.fetch = originalFetch;
    restoreEnvironment("OPENAI_API_KEY", originalValues.key);
    restoreEnvironment("OPENAI_MODEL", originalValues.model);
    restoreEnvironment("OPENAI_MAX_OUTPUT_TOKENS", originalValues.tokens);
    restoreEnvironment("OPENAI_REASONING_EFFORT", originalValues.effort);
  }
});

function restoreEnvironment(name: string, value: string | undefined) {
  if (value === undefined) {
    Deno.env.delete(name);
  } else {
    Deno.env.set(name, value);
  }
}
