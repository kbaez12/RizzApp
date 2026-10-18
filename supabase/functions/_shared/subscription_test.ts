import { assert, assertEquals, assertThrows } from "jsr:@std/assert";
import { authenticatedUserId, isUserId } from "./auth.ts";
import { performReservedOperation } from "./idempotency.ts";
import { constantTimeEqual } from "./revenuecat.ts";
import {
  reservationAllowsModelCall,
  reservationDenial,
} from "./subscription.ts";

const request = new Request("https://example.test/functions/v1/generate", {
  method: "POST",
});

Deno.test("authenticated user id comes only from JWT claims", () => {
  const id = "123e4567-e89b-42d3-a456-426614174000";
  assertEquals(authenticatedUserId({ id }), id);
  assertEquals(authenticatedUserId({ sub: id }), id);
  assertThrows(() => authenticatedUserId(null));
  assertThrows(() => authenticatedUserId({ id: "not-a-user-id" }));
});

Deno.test("JWT verification rejects missing and client-shaped identities", () => {
  assertThrows(() => authenticatedUserId({}));
  assertThrows(() => authenticatedUserId({ id: "" }));
  assertThrows(() => authenticatedUserId({ sub: "$RCAnonymousID:abc" }));
  assertThrows(() => authenticatedUserId({ id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee" }));
  const id = "123e4567-e89b-42d3-a456-426614174000";
  assertEquals(
    authenticatedUserId({ id, sub: "00000000-0000-4000-8000-000000000000" }),
    id,
  );
});

Deno.test("RevenueCat alias UUID validation rejects anonymous ids", () => {
  assert(isUserId("123e4567-e89b-42d3-a456-426614174000"));
  assertEquals(isUserId("$RCAnonymousID:abc"), false);
});

Deno.test("webhook secret comparison handles unequal lengths", () => {
  assert(constantTimeEqual("Bearer shared-secret", "Bearer shared-secret"));
  assertEquals(constantTimeEqual("Bearer shared", "Bearer shared-secret"), false);
  assertEquals(constantTimeEqual("", "Bearer shared-secret"), false);
});

Deno.test("mandatory subscription denial never allows a model call", async () => {
  let modelCalls = 0;
  const reservation = {
    outcome: "subscription_required",
    usage: { subscribed: false, remaining: 0, limit: 200 },
  };
  const denial = reservationDenial(reservation.outcome);
  assert(denial);
  assertEquals(denial.status, 402);
  assertEquals(denial.code, "SUBSCRIPTION_REQUIRED");
  assertEquals(reservationAllowsModelCall(reservation.outcome), false);

  if (reservationAllowsModelCall(reservation.outcome)) {
    await performReservedOperation(reservation, request, async () => {
      modelCalls += 1;
      return "should-not-run";
    });
  }

  assertEquals(modelCalls, 0);
});

Deno.test("usage limit denial also blocks OpenAI", () => {
  const denial = reservationDenial("usage_limit_exceeded");
  assert(denial);
  assertEquals(denial.status, 429);
  assertEquals(denial.code, "USAGE_LIMIT_EXCEEDED");
  assertEquals(reservationAllowsModelCall("usage_limit_exceeded"), false);
});

Deno.test("only a reserved outcome may invoke OpenAI", () => {
  assertEquals(reservationAllowsModelCall("reserved"), true);
  assertEquals(reservationAllowsModelCall("duplicate"), false);
  assertEquals(reservationAllowsModelCall("subscription_required"), false);
  assertEquals(reservationDenial("reserved"), null);
  assertEquals(reservationDenial("duplicate"), null);
});
