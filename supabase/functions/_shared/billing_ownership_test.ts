import { assertEquals } from "jsr:@std/assert";
import { revenueCatOwnerCandidates } from "./revenuecat.ts";

const A = "123e4567-e89b-42d3-a456-426614174000";
const B = "123e4567-e89b-42d3-a456-426614174001";

Deno.test("transfer owner comes exclusively from destinations", () => {
  assertEquals(revenueCatOwnerCandidates("TRANSFER", A, [A], [B]), [B]);
});
Deno.test("missing transfer destination never falls back to source", () => {
  assertEquals(revenueCatOwnerCandidates("TRANSFER", A, [A], []), []);
});
Deno.test("ambiguous transfer destinations remain ambiguous", () => {
  assertEquals(revenueCatOwnerCandidates("TRANSFER", A, [], [A, B]), [A, B]);
});
Deno.test("duplicate destinations identify one owner", () => {
  assertEquals(revenueCatOwnerCandidates("TRANSFER", A, [], [B, B]), [B]);
});
Deno.test("canonical lifecycle identity takes precedence over history", () => {
  assertEquals(revenueCatOwnerCandidates("RENEWAL", B, [A, B], []), [B]);
});
Deno.test("anonymous lifecycle with conflicting UUID aliases fails closed", () => {
  assertEquals(
    revenueCatOwnerCandidates(
      "INITIAL_PURCHASE",
      "$RCAnonymousID:test",
      [A, B],
      [],
    ),
    [A, B],
  );
});
