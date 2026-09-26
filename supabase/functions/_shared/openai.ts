// Minimal OpenAI Responses API client.
//
// The API key exists ONLY here, read from function secrets — never in the
// iOS client. Every request sets `store: false` so OpenAI does not retain
// the request/response for us. That is NOT the same as Zero Data Retention
// (a separate account-level agreement we have not configured); do not claim
// ZDR anywhere in the app or store listing.

const ENDPOINT = "https://api.openai.com/v1/responses";

/** Model is configurable server-side (function secret), defaulting to the
 * launch model. No model names are ever exposed to the client. */
export function configuredModel(): string {
  return Deno.env.get("OPENAI_MODEL") ?? "gpt-5.6-terra";
}

export interface OpenAIResult {
  parsed: Record<string, unknown>;
  inputTokens: number | null;
  outputTokens: number | null;
}

export class OpenAIError extends Error {
  constructor(message: string, readonly retryable: boolean) {
    super(message);
  }
}

interface ImagePayload {
  base64: string;
}

/** One structured-output call. Throws OpenAIError; callers decide on retry. */
export async function generateStructured(options: {
  system: string;
  instruction: string;
  image?: ImagePayload;
  schema: unknown;
  schemaName: string;
  signal?: AbortSignal;
}): Promise<OpenAIResult> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    throw new OpenAIError("OPENAI_API_KEY is not configured.", false);
  }

  const userContent: unknown[] = [
    { type: "input_text", text: options.instruction },
  ];
  if (options.image) {
    userContent.push({
      type: "input_image",
      // Data URL keeps the image in-request; nothing is uploaded or stored.
      image_url: `data:image/jpeg;base64,${options.image.base64}`,
    });
  }

  let response: Response;
  try {
    response = await fetch(ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      signal: options.signal,
      body: JSON.stringify({
        model: configuredModel(),
        store: false,
        input: [
          {
            role: "system",
            content: [{ type: "input_text", text: options.system }],
          },
          { role: "user", content: userContent },
        ],
        text: {
          format: {
            type: "json_schema",
            name: options.schemaName,
            strict: true,
            schema: options.schema,
          },
        },
      }),
    });
  } catch (error) {
    const aborted = error instanceof DOMException && error.name === "AbortError";
    throw new OpenAIError(aborted ? "OpenAI request timed out." : "OpenAI request failed.", !aborted);
  }

  if (!response.ok) {
    // 429/5xx are worth one retry; 4xx config/validation errors are not.
    const retryable = response.status === 429 || response.status >= 500;
    // Body is read but NOT logged: it can echo request content.
    await response.body?.cancel();
    throw new OpenAIError(`OpenAI returned ${response.status}.`, retryable);
  }

  const payload = await response.json();
  const text = extractOutputText(payload);
  if (!text) {
    throw new OpenAIError("OpenAI returned no usable output.", true);
  }

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new OpenAIError("OpenAI output was not valid JSON.", true);
  }

  return {
    parsed,
    inputTokens: payload?.usage?.input_tokens ?? null,
    outputTokens: payload?.usage?.output_tokens ?? null,
  };
}

/** Pulls the assistant text out of the Responses `output` array. Reasoning
 * models interleave other item types, so scan rather than index. */
function extractOutputText(payload: {
  output_text?: string;
  output?: Array<{
    type?: string;
    content?: Array<{ type?: string; text?: string }>;
  }>;
}): string | null {
  if (typeof payload.output_text === "string" && payload.output_text.length > 0) {
    return payload.output_text;
  }
  for (const item of payload.output ?? []) {
    if (item.type !== "message") continue;
    for (const part of item.content ?? []) {
      if (part.type === "output_text" && part.text) {
        return part.text;
      }
    }
  }
  return null;
}
