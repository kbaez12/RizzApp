# RizzApp (working title)

SwiftUI iOS app that helps users craft replies to dating/text conversations
using AI. Screenshots/text are processed by our backend; no accounts required.

- Minimum iOS: 17.0
- Architecture: MVVM, feature-oriented, `@Observable` view models
- Project generation: [XcodeGen](https://github.com/yonaskolb/XcodeGen) via `project.yml`
  (no `.xcodeproj` is committed)

## Building (macOS required)

This repo is authored on Windows/Cursor; **nothing here has been compiled yet**.
On a Mac:

```bash
brew install xcodegen
xcodegen generate
open RizzApp.xcodeproj
```

Then in Xcode:

1. Select the `RizzApp` scheme and an iOS 17+ simulator, and build (⌘B).
2. Signing: set your development team under Signing & Capabilities
   (bundle ID `com.placeholder.rizzapp` is a placeholder — replace before
   App Store Connect setup).
3. Run the unit tests (⌘U) — `RizzAppTests` contains a decoding smoke test.

## Backend (Supabase Edge Functions)

Phase 4A: the functions return **canned data only** (no AI, no database).
Mock vs live is selected in `RizzApp/Core/Networking/APIConfig.swift`
(`AppConfig.serviceMode`) — views never know which mode is active.

### Local development (requires Supabase CLI + Docker)

```bash
# one-time
brew install supabase/tap/supabase     # or see supabase.com/docs for Windows
cp supabase/functions/.env.example supabase/functions/.env

# run the local stack + functions
supabase start
supabase functions serve --env-file supabase/functions/.env
```

Then:
1. `supabase start` prints the local API URL (default `http://127.0.0.1:54321`)
   and a publishable/anon key — paste the key into
   `APIConfig.localDevelopment` in `APIConfig.swift`.
2. Set `AppConfig.serviceMode = .liveDevelopment`.
3. Local HTTP works from the iOS **simulator** only (loopback is ATS-exempt);
   a physical device cannot reach your machine's 127.0.0.1.

Error simulation (DEBUG builds + local `.env` only): set
`AppConfig.debugErrorScenario` to `"quota"`, `"unauthorized"`,
`"rate_limit"`, `"server_error"`, `"invalid_request"`, or `"malformed"`.

Edge function tests: `deno test supabase/functions/_shared/contracts_test.ts`

### Remote dev project

```bash
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase functions deploy generate
supabase functions deploy usage
```

Fill `APIConfig.remoteDevelopment` with the project URL and publishable key
(Dashboard → Settings → API). The publishable key is client-safe; secret /
service-role keys must never enter the iOS app.

## Structure

```
RizzApp/
  App/            entry point, flow model, navigation root
  Core/Models/    value types shared across features (API-contract Codables)
  DesignSystem/   theme tokens + reusable components
  Features/       one folder per screen (Home, Input, GoalSelection, ...)
RizzAppTests/     unit tests
project.yml       XcodeGen spec
```

## Security note

No private keys (OpenAI, Supabase service role, RevenueCat secret) ever ship
in this client. The app talks only to our backend.
