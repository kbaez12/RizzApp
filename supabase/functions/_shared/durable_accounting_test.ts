import { assertEquals, assertStringIncludes } from "jsr:@std/assert";
import { handleGenerate } from "../generate/index.ts";
import { handleAnalyze } from "../analyze/index.ts";
import { CANNED_ANALYSIS } from "./analysis.ts";

const id = "123e4567-e89b-42d3-a456-426614174000";
const usage = { remaining: 199, limit: 200, refinements_remaining: 2 };
type Reply = { data: Record<string, unknown> | null; error: unknown } | null;
const committed: Reply = { data: { outcome: "committed", usage }, error: null };
const failed: Reply = {
  data: null,
  error: { message: "database unavailable" },
};

for (const endpoint of ["generate", "analyze"] as const) {
  async function run(options: {
    commits?: Array<Reply | Error>;
    state?: Reply | Error;
    generationFails?: boolean;
    releaseFails?: boolean;
    reservation?: Reply | Error;
    refinement?: boolean;
  } = {}) {
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    let modelCalls = 0;
    const commits = [...(options.commits ?? [committed])];
    const admin = {
      async rpc(name: string, args: Record<string, unknown>) {
        calls.push({ name, args });
        let result: Reply | Error;
        switch (name) {
          case "check_rate_limit":
            return { data: { allowed: true }, error: null };
          case "reserve_user_usage":
            result = options.reservation ??
              {
                data: { outcome: "reserved", reservation_id: id, usage },
                error: null,
              };
            break;
          case "commit_user_reservation":
            result = commits.shift() ?? failed;
            break;
          case "get_user_reservation_status":
            result = options.state ?? failed;
            break;
          case "release_user_reservation":
            result = options.releaseFails
              ? new Error("release transport")
              : { data: { outcome: "released" }, error: null };
            break;
          default:
            throw new Error("Unexpected RPC");
        }
        if (result instanceof Error) throw result;
        return result;
      },
    };
    const request = new Request(`https://example.test/${endpoint}`, {
      method: "POST",
      body: JSON.stringify({
        request_id: id,
        input: { kind: "text", text: "them: hello" },
        goal: "flirty",
        refinement: options.refinement ? "shorter" : null,
      }),
    });
    const ctx = { supabaseAdmin: admin, userClaims: { sub: id } };
    const beforeModel = () => {
      modelCalls++;
      if (options.generationFails) {
        throw new Error("model failure with private content");
      }
    };
    const response = endpoint === "generate"
      ? await handleGenerate(request, ctx, async () => {
        beforeModel();
        return {
          responses: [{
            type: "flirty",
            label: "Flirty",
            text: "PRIVATE_OUTPUT",
          }],
          inputTokens: 1,
          outputTokens: 1,
          retried: false,
          remainingProblems: 0,
        };
      })
      : await handleAnalyze(request, ctx, async () => {
        beforeModel();
        return {
          analysis: { ...CANNED_ANALYSIS, vibe: "PRIVATE_OUTPUT" },
          inputTokens: 1,
          outputTokens: 1,
        };
      });
    const body = await response.json();
    // Every accounting RPC uses precisely the original reservation ID.
    for (
      const call of calls.filter((c) =>
        c.name !== "check_rate_limit" && c.name !== "reserve_user_usage"
      )
    ) {
      assertEquals(call.args, { p_reservation_id: id });
    }
    if (response.status !== 200) {
      assertEquals(body.responses, undefined);
      assertEquals(body.analysis, undefined);
      assertEquals(JSON.stringify(body).includes("PRIVATE_OUTPUT"), false);
    }
    return { response, body, calls: calls.map((c) => c.name), modelCalls };
  }
  Deno.test(`${endpoint}: successful commit gates output`, async () => {
    const r = await run();
    assertEquals(r.response.status, 200);
    assertEquals(r.body.usage, usage);
    assertEquals(r.modelCalls, 1);
    assertStringIncludes(JSON.stringify(r.body), "PRIVATE_OUTPUT");
  });
  Deno.test(`${endpoint}: generation failure refunds without commit`, async () => {
    const r = await run({ generationFails: true });
    assertEquals(r.response.status, 500);
    assertEquals(r.calls.at(-1), "release_user_reservation");
    assertEquals(r.calls.includes("commit_user_reservation"), false);
  });
  Deno.test(`${endpoint}: failed refund stays pending without crashing`, async () => {
    const r = await run({ generationFails: true, releaseFails: true });
    assertEquals(r.response.status, 500);
  });
  for (
    const [label, reply] of Object.entries({
      rpc_error: failed,
      missing_response: null,
      null_data: { data: null, error: null },
      unexpected: { data: { outcome: "surprise" }, error: null },
      not_committed: { data: { outcome: "not_reserved" }, error: null },
      error_with_committed_data: {
        data: { outcome: "committed" },
        error: "transport",
      },
      thrown_transport: new Error("lost acknowledgment"),
    })
  ) {
    Deno.test(`${endpoint}: ${label} never delivers or releases`, async () => {
      const r = await run({ commits: [reply, reply] });
      assertEquals(r.response.status, 503);
      assertEquals(
        r.calls.filter((c) => c === "commit_user_reservation").length,
        2,
      );
      assertEquals(r.calls.includes("release_user_reservation"), false);
      assertEquals(r.modelCalls, 1);
    });
  }
  Deno.test(`${endpoint}: lost first acknowledgment recovers same committed reservation`, async () => {
    const r = await run({
      commits: [new Error("ack lost after commit"), committed],
    });
    assertEquals(r.response.status, 200);
    assertEquals(r.modelCalls, 1);
    assertEquals(r.calls.includes("release_user_reservation"), false);
  });
  Deno.test(`${endpoint}: authoritative read recovers both lost commit acknowledgments`, async () => {
    const r = await run({
      commits: [failed, new Error("ack lost")],
      state: { data: { status: "committed", usage }, error: null },
    });
    assertEquals(r.response.status, 200);
    assertEquals(r.body.usage, usage);
    assertEquals(r.calls.at(-1), "get_user_reservation_status");
  });
  for (const state of ["reserved", "released", "missing", "unexpected"]) {
    Deno.test(`${endpoint}: authoritative ${state} state withholds output`, async () => {
      const r = await run({
        commits: [failed, failed],
        state: { data: { status: state }, error: null },
      });
      assertEquals(r.response.status, 503);
      assertEquals(r.calls.includes("release_user_reservation"), false);
    });
  }
  Deno.test(`${endpoint}: status error cannot confirm committed data`, async () => {
    const r = await run({
      commits: [failed, failed],
      state: { data: { status: "committed" }, error: "read error" },
    });
    assertEquals(r.response.status, 503);
  });
  Deno.test(`${endpoint}: status transport loss withholds output`, async () => {
    const r = await run({
      commits: [failed, failed],
      state: new Error("lost read"),
    });
    assertEquals(r.response.status, 503);
  });
  for (const prior_status of ["reserved", "committed", "released"]) {
    Deno.test(`${endpoint}: duplicate after uncertain ${prior_status} completion does no work`, async () => {
      await run({ commits: [failed, failed] });
      const r = await run({
        reservation: {
          data: {
            outcome: "duplicate",
            prior_status,
            reservation_id: id,
            usage,
          },
          error: null,
        },
      });
      assertEquals(r.response.status, 409);
      assertEquals(r.modelCalls, 0);
      assertEquals(r.calls, ["check_rate_limit", "reserve_user_usage"]);
    });
  }
  Deno.test(`${endpoint}: reserve transport error never starts model or refunds`, async () => {
    const r = await run({ reservation: new Error("lost reservation ack") });
    assertEquals(r.response.status, 503);
    assertEquals(r.modelCalls, 0);
    assertEquals(r.calls.includes("release_user_reservation"), false);
  });
  for (const reservation of [failed, { data: null, error: null }]) {
    Deno.test(`${endpoint}: reservation RPC failure does not generate or refund`, async () => {
      const r = await run({ reservation });
      assertEquals(r.response.status, 503);
      assertEquals(r.modelCalls, 0);
      assertEquals(r.calls.includes("release_user_reservation"), false);
      assertStringIncludes(r.body.error.message, "same request ID");
    });
  }
  for (
    const outcome of [
      "subscription_required",
      "usage_limit_exceeded",
      "unknown",
    ]
  ) {
    Deno.test(`${endpoint}: ${outcome} reservation blocks model`, async () => {
      const r = await run({ reservation: { data: { outcome }, error: null } });
      assertEquals(r.modelCalls, 0);
      assertEquals(r.response.status === 200, false);
    });
  }
  if (endpoint === "generate") {
    Deno.test("generate: failed refinement refunds only before commitment", async () => {
      const r = await run({ generationFails: true, refinement: true });
      assertEquals(r.response.status, 500);
      assertEquals(r.calls.at(-1), "release_user_reservation");
      const uncertain = await run({
        refinement: true,
        commits: [failed, failed],
      });
      assertEquals(uncertain.response.status, 503);
      assertEquals(uncertain.calls.includes("release_user_reservation"), false);
    });
  }
}
