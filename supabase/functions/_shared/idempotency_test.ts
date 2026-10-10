import { assertEquals } from "jsr:@std/assert";
import { performReservedOperation } from "./idempotency.ts";

const request = new Request("https://example.test/functions/v1/generate", {
  method: "POST",
});
const usage = {
  remaining: 4,
  limit: 5,
  tier: "free",
  refinements_remaining: 2,
};

Deno.test("duplicate reservations never execute expensive work", async () => {
  let openAICalls = 0;

  for (let attempt = 0; attempt < 10; attempt += 1) {
    const result = await performReservedOperation(
      { outcome: "duplicate", prior_status: "committed", usage },
      request,
      async () => {
        openAICalls += 1;
        return "generated";
      },
    );

    assertEquals(result.performed, false);
    if (!result.performed) {
      assertEquals(result.response.status, 409);
      const body = await result.response.json();
      assertEquals(body.error.code, "DUPLICATE_REQUEST");
      assertEquals(body.usage, usage);
    }
  }

  assertEquals(openAICalls, 0);
});

Deno.test("only a newly reserved request executes expensive work", async () => {
  let openAICalls = 0;
  const result = await performReservedOperation(
    { outcome: "reserved", reservation_id: crypto.randomUUID(), usage },
    request,
    async () => {
      openAICalls += 1;
      return "generated";
    },
  );

  assertEquals(result.performed, true);
  assertEquals(openAICalls, 1);
  if (result.performed) assertEquals(result.value, "generated");
});
