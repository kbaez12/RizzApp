# RizzApp (working title)

A simple iOS app: upload a screenshot or paste a conversation, pick a
goal, get three AI replies (Natural / Bolder / Make a Move), copy one.
Five free analyses, then a Plus subscription.

No accounts. No profiles. No conversation history.

- Minimum iOS: 17.0
- SwiftUI, `@Observable`, `NavigationStack`, PhotosPicker
- Backend: Supabase Edge Functions + Postgres quota
- AI: OpenAI Responses API (`gpt-5.6-terra`, configurable), `store: false`
- Subscriptions: RevenueCat + StoreKit, entitlement `plus`

## Mock vs live

Flip one line in `RizzApp/Core/Networking/APIConfig.swift`:

```swift
static let serviceMode: ServiceMode = .mock            // offline UI
static let serviceMode: ServiceMode = .liveDevelopment // real backend
```

Views never know which mode is running. Mock mode keeps
`MockGenerationService` / `MockUsageStore` / `MockSubscriptionService`.

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

Paste the printed publishable key into `APIConfig.localDevelopment`.
Local HTTP works from the iOS **simulator** only.

```bash
deno test supabase/functions/_shared/contracts_test.ts
deno test supabase/functions/_shared/cringe_guard_test.ts

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
