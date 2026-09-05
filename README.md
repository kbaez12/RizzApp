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
