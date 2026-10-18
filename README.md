# RizzApp (working title)

A simple iOS app: upload a screenshot or paste a conversation, pick a
goal, get three AI replies (Natural / Bolder / Make a Move), copy one.
An active subscription is required; subscribers receive a monthly
generation allowance enforced by the backend.

No visible account or profile UI. A background Supabase anonymous account
securely binds backend requests and subscription state. No conversation history.

- Minimum iOS: 17.0
- SwiftUI, `@Observable`, `NavigationStack`, PhotosPicker
- Backend: Supabase Edge Functions + Postgres quota
- AI: OpenAI Responses API (`OPENAI_MODEL`, default `gpt-5.6-luna`), `store: false`
- Subscriptions: RevenueCat + StoreKit, entitlement `plus`

## Mock vs live

Mock mode is the default. To opt into live development, add these
environment variables to the Debug scheme:

```text
GREENSHOT_SERVICE_MODE=liveDevelopment
SUPABASE_ENVIRONMENT=development
SUPABASE_DEV_URL=http://127.0.0.1:54321
SUPABASE_DEV_PUBLISHABLE_KEY=<local publishable key>
```

For a hosted development project, also set
`SUPABASE_DEV_PROJECT_REF=<project ref>` and
`GREENSHOT_ALLOW_HOSTED_DEV=true`. Release builds ignore this mode.

Views never know which mode is running. Mock mode keeps
`MockGenerationService` / `MockUsageStore` / `MockSubscriptionService`.
Release builds never fall back to mocks. Provide the public
`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, and
`REVENUECAT_PUBLIC_SDK_KEY` build settings; a missing or placeholder value
shows a blocking configuration screen.

## Building (macOS required)

This repo is authored on Windows. **Nothing here has been compiled.**

```bash
brew install xcodegen
xcodegen generate
open RizzApp.xcodeproj
```

See [LAUNCH.md](LAUNCH.md) for signing, secrets, subscriptions, and
TestFlight. See the same file for the URLs, bundle ID, and icon you
must provide before submission.

## Local backend

Needs the Supabase CLI and Docker.

```bash
cp supabase/functions/.env.example supabase/functions/.env
# put a real OPENAI_API_KEY in .env (never commit it)

supabase start
supabase db reset
supabase functions serve --env-file supabase/functions/.env
```

Put the printed URL and publishable key in the Debug scheme variables
above. Local HTTP works from the iOS **simulator** only.

```bash
deno test --allow-env supabase/functions/_shared

INTEGRATION=true SUPABASE_URL=http://127.0.0.1:54321 \
PUBLISHABLE_KEY=<key> \
deno test --allow-net --allow-env supabase/functions/tests/integration_test.ts

# Real AI quality pass (spends money):
INTEGRATION=true SUPABASE_URL=http://127.0.0.1:54321 \
PUBLISHABLE_KEY=<key> \
deno run --allow-net --allow-env supabase/functions/tests/quality_check.ts
```

## Structure

```
RizzApp/          SwiftUI app
RizzAppTests/     unit tests (no network)
supabase/         Edge Functions, migrations, seed
LAUNCH.md         everything you do by hand to ship
project.yml       XcodeGen spec
```

## Security

No OpenAI key, Supabase service-role key, or RevenueCat secret is in
this client. The app talks only to our backend. See LAUNCH.md §7.
