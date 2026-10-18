# Launch checklist

This is the full list of things that must be done **outside this repo**
before TestFlight and the App Store. The app is authored; none of it has
been compiled or submitted from this Windows environment.

Replace every `example.com` / `PLACEHOLDER` / `YOUR-` value before
submission. App Review rejects unreachable privacy/terms URLs.

---

## 0. Things I need from you

| Item | Current placeholder | Where it goes |
| --- | --- | --- |
| Final **app name** | Greenshot | Xcode display name, App Store Connect, RevenueCat |
| **Bundle ID** | `com.zenomedia.greenshot` | `project.yml`, Apple Developer, App Store Connect, RevenueCat |
| **App icon** | none | 1024×1024 PNG, no alpha, plus the Xcode asset catalog |
| **Privacy Policy URL** | `https://rizzapp.example.com/privacy` | `LegalLinks.swift`, App Store Connect, paywall |
| **Terms of Use URL** | `https://rizzapp.example.com/terms` | `LegalLinks.swift`, paywall |
| **Support URL or email** | `mailto:support@rizzapp.example.com` | `LegalLinks.swift`, App Store Connect |
| Apple Developer **Team ID** | — | Xcode signing |
| OpenAI **API key** | — | Supabase secret `OPENAI_API_KEY` |
| RevenueCat **public SDK key** | — | Release build setting `REVENUECAT_PUBLIC_SDK_KEY` |
| RevenueCat **webhook Authorization value** | — | Supabase secret `REVENUECAT_WEBHOOK_SECRET` |

---

## 1. Mac / Xcode (required — this repo is Windows-authored)

```bash
brew install xcodegen
cd <this-repo>
xcodegen generate
open RizzApp.xcodeproj
```

Then in Xcode:

1. Signing & Capabilities → your Team. Confirm the App Store Connect app
   uses the existing `com.zenomedia.greenshot` bundle ID exactly.
2. Add an App Icon to `Assets.xcassets` (create the catalog if XcodeGen
   did not). 1024×1024, no transparency.
3. Confirm `MARKETING_VERSION` (`0.1.0`) and `CURRENT_PROJECT_VERSION`
   (`1`) in `project.yml`. Bump the build number for every TestFlight
   upload.
4. Scheme: `RizzApp`, any iOS 17+ simulator, ⌘B. Fix any compile
   issues (none of this has been compiled).
5. ⌘U — run the unit tests.
6. SPM should resolve RevenueCat automatically from `project.yml`.
   If it does not: File → Add Package Dependencies →
   `https://github.com/RevenueCat/purchases-ios` (5.88.0 or newer) → product
   `RevenueCat`.

**ATS:** production traffic is HTTPS. Local `http://127.0.0.1` is
loopback-exempt and only works from the simulator.

**PhotosPicker** does not require a photo-library usage description.

**App Attest** capability is **not** enabled. Do not block TestFlight
on it. See `AppAttestService.swift` and section 7.

---

## 2. Supabase

```bash
brew install supabase/tap/supabase   # + Docker
cp supabase/functions/.env.example supabase/functions/.env
# edit .env: real OPENAI_API_KEY, optional OPENAI_MODEL, webhook secret

supabase start
supabase db reset                    # migrations + seed.sql
supabase functions serve --env-file supabase/functions/.env
```

`supabase start` prints the local URL (`http://127.0.0.1:54321`) and a
publishable/anon key. Put them in the Debug scheme environment as
`SUPABASE_DEV_URL` and `SUPABASE_DEV_PUBLISHABLE_KEY`, then set
`SUPABASE_ENVIRONMENT=development` and
`GREENSHOT_SERVICE_MODE=liveDevelopment`.

Hosted project:

```bash
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set OPENAI_MODEL=gpt-5.6-luna
supabase secrets set OPENAI_MAX_OUTPUT_TOKENS=500
supabase secrets set OPENAI_REASONING_EFFORT=low
supabase secrets set REVENUECAT_WEBHOOK_SECRET=a-long-random-string
supabase secrets set REVENUECAT_API_KEY=sk-...
supabase secrets set REVENUECAT_APP_ID=app_...
supabase secrets set REVENUECAT_ENTITLEMENT_ID=plus
supabase secrets set REVENUECAT_PRODUCT_IDS=<monthly-id>,<yearly-id>
supabase secrets set REVENUECAT_EXPECTED_ENVIRONMENT=PRODUCTION
supabase secrets set REVENUECAT_EXPECTED_STORE=APP_STORE
supabase functions deploy generate
supabase functions deploy analyze
supabase functions deploy usage
supabase functions deploy subscription-sync
supabase functions deploy revenuecat-webhook
```

For a hosted development test, use the same Debug scheme settings plus
`SUPABASE_DEV_PROJECT_REF=YOUR-PROJECT-REF` and
`GREENSHOT_ALLOW_HOSTED_DEV=true`. Never put the service-role or secret
key in the iOS app.

Confirm `DEV_ERROR_SIMULATION` is **unset** on the hosted project.

Webhook URL to give RevenueCat:

```
https://YOUR-PROJECT-REF.supabase.co/functions/v1/revenuecat-webhook
```

Authorization header value = the `REVENUECAT_WEBHOOK_SECRET` you set.

Hosted Auth and RevenueCat Customer Authentication (confirm in dashboards
before any live Release; this repo cannot enable them):

- Authentication → Providers → **Anonymous sign-ins: ON**
- CAPTCHA / Turnstile: **off** for this native client (the app sends `{}`
  and cannot supply a captcha token)
- JWT signing: **asymmetric** ECC/RSA keys, not HS256
- Publishable API key prefix: `sb_publishable_`
- RevenueCat project **Customer Authentication private beta** enabled
- RevenueCat Auth method: OIDC issuer
  `https://YOUR-PROJECT-REF.supabase.co/auth/v1`, Client ID `authenticated`
- RevenueCat public SDK key prefix: `appl_`

---

## 3. OpenAI

1. Create an API key at platform.openai.com. Restrict it if possible.
2. Put it **only** in Supabase secrets (`OPENAI_API_KEY`).
3. Confirm Responses API, image input, and strict structured-output access
   for `gpt-5.6-luna`; if unavailable, set `OPENAI_MODEL` to another supported model.
4. Every request sends `store: false`. That is **not** Zero Data
   Retention — do not claim ZDR in the App Store or privacy policy
   unless you have a ZDR agreement with OpenAI.
5. Set a billing limit you are comfortable with. Vision + a capable
   model is not cheap; the quality harness (`quality_check.ts`) will
   spend real money.

Quality pass (spends API calls, uses the Plus seed installation):

```bash
INTEGRATION=true SUPABASE_URL=http://127.0.0.1:54321 \
PUBLISHABLE_KEY=<local key> \
deno run --allow-net --allow-env supabase/functions/tests/quality_check.ts
```

Iterate on `supabase/functions/_shared/prompt.ts` if replies are weak.

---

## 4. RevenueCat + App Store Connect products

### App Store Connect first

1. Create the app with the final name and bundle ID.
2. Agreements, Tax, and Banking must be complete or subscriptions
   will not work, even in sandbox.
3. Features → Subscriptions:
   - Create the final subscription group.
   - Create owner-approved monthly and yearly products; choose the final
     identifiers and prices in App Store Connect.
4. Localization for each product (display name + description).
5. Submit the subscription group for review with the first build
   (or as a standalone subscription review, depending on current
   ASC flow).

### RevenueCat

1. Create a project, iOS app, bundle ID matching ours.
2. Upload the In-App Purchase Key (p8) from App Store Connect → Users
   and Access → Integrations → In-App Purchase.
3. Products: import the exact monthly and yearly products created above.
4. Entitlement: `plus` — attach both products.
5. Add both products to the current offering using their matching duration
   package types.
6. Public SDK key (`appl_…`) → Release build setting
   `REVENUECAT_PUBLIC_SDK_KEY`.
7. Webhooks → the Supabase URL above. Authorization header = the
   secret. The RevenueCat App User ID is the authenticated Supabase
   anonymous user UUID. The backend independently derives this identity
   from the bearer token during subscription sync.
8. Configure RevenueCat customer authentication against Supabase OIDC
   (`https://YOUR-PROJECT-REF.supabase.co/auth/v1`, audience
   `authenticated`) after enabling asymmetric Supabase JWT signing.
   Customer Authentication is currently a RevenueCat private beta; obtain
   production access from RevenueCat before submitting this build.
9. Choose and test RevenueCat's transfer behavior so an explicit Apple
   restore moves access to the new anonymous user without creating a new
   usage allowance.
10. Sandbox testers: App Store Connect → Users and Access → Sandbox.

The client never tells the backend it is premium. Only the webhook
and authenticated server-to-server subscription reconciliation update
entitlement state.

---

## 5. App Store Connect listing

### Version / build

- Version: `0.1.0` (or whatever you set).
- Build: increment `CURRENT_PROJECT_VERSION` for every upload.

### URLs (required)

- Privacy Policy URL — the real one, not `example.com`.
- Support URL.
- Marketing URL — optional.

### App Privacy (nutrition labels)

Be accurate. Suggested starting answers (review with counsel):

- Data used to track you: **No**.
- Data linked to you:
  - Purchase History — yes, used for App Functionality (StoreKit /
    RevenueCat). Not used for tracking.
- Data not linked to you:
  - Other User Content (the conversation the user chooses to send) —
    used for App Functionality, processed by a third-party AI
    provider, **not stored by us** as part of the generation flow.
    Third-party processing: disclose OpenAI (and RevenueCat / Apple
    for purchases).
- We do **not** collect name, email, phone, precise location, or
  contacts.

### Age rating

Likely 17+ (frequent/intense mature/suggestive themes — this is a
dating-reply app). Do not market it to children. No UGC posting,
no social graph.

### Review notes (suggested)

> This app helps a user draft a reply to a conversation they already
> have. They select one screenshot or paste text; that content is sent
> to our backend and then to OpenAI to generate three reply options.
> We create a background anonymous account only to authenticate requests
> and bind subscription access. We do not store conversations. An
> auto-renewing subscription is required (monthly / yearly) via StoreKit,
> with a disclosed monthly generation allowance. Restore Purchases is on
> the paywall and in
> Settings. Sandbox: use the attached sandbox Apple ID.

### Screenshots

Need 6.7" (iPhone 15 Pro Max / 16 Pro Max) and 6.1" sizes at
minimum, in the dark UI:

1. Home
2. Screenshot preview
3. Goal selection
4. Results (three cards)
5. Paywall
6. Settings (optional)

No device frames required; Apple prefers raw screenshots.

### Archive / TestFlight

1. Destination → Any iOS Device (arm64).
2. Product → Archive.
3. Distribute App → App Store Connect → Upload.
4. Wait for processing; add to a TestFlight group.
5. Internal testers see it within minutes; external testers need a
   brief Beta App Review the first time.

---

## 6. TestFlight submission checklist

- [ ] Final app name + bundle ID set
- [ ] Real privacy / terms / support URLs live and wired in `LegalLinks.swift`
- [ ] App icon in the asset catalog
- [ ] Signing team set, archive succeeds
- [ ] Debug scheme explicitly opts into the hosted development project
      (production RevenueCat wiring remains separate)
- [ ] OpenAI secret set; a real generation succeeds on device
- [ ] RevenueCat public key set; sandbox purchase of monthly works
- [ ] Sandbox purchase of yearly works
- [ ] Restore Purchases works
- [ ] Webhook received `INITIAL_PURCHASE` and the installation row
      flipped to `plus` (check in Supabase Table Editor)
- [ ] New/inactive account remains on the non-dismissible paywall
- [ ] Active subscriber reaches the monthly cap without losing subscription status
- [ ] Privacy disclosure appears once, then not again
- [ ] Start Over clears the conversation and does not reset quota
- [ ] Offline generation shows a friendly error
- [ ] Failed OpenAI call refunds quota (watch `usage` after a forced
      failure, or `fail_after_reserve` on a local stack)
- [ ] `DEV_ERROR_SIMULATION` is **off** in production
- [ ] No secret keys in the IPA (search the binary for `sk-` /
      `sb_secret` / `RevenueCat` secret)
- [ ] Version + build bumped
- [ ] App Privacy answers filled
- [ ] Review notes pasted
- [ ] Screenshots uploaded
- [ ] Subscriptions attached to the version
- [ ] Export compliance: typically "No" unless you add non-exempt
      encryption (HTTPS-only is usually exempt)

---

## 7. Security posture (honest)

**Shipped for MVP / TestFlight**

- OpenAI key, Supabase service-role, RevenueCat secret: server only
- Supabase anonymous-user JWT validation on protected functions
- Atomic Postgres quota + idempotency + refund-on-failure
- Request validation and size limits
- Per-installation rate limit (12 requests / 60s)
- RLS with zero public policies on quota tables
- No conversation content in the database or logs
- `store: false` on every OpenAI call (not ZDR)

**Not done — do not block TestFlight, finish before broad public scale**

- App Attest / DeviceCheck (scaffold in `AppAttestService.swift`)
- IP-level rate limiting (e.g. Supabase / Cloudflare)
- Production OpenAI spend alerts and a hard project cap
- A scheduled job to release stale quota reservations
  (opportunistic cleanup already runs on the next request)

The publishable key can be extracted from the IPA. Quota + rate
limits are what stop a leaked key from becoming an unlimited OpenAI
bill. App Attest is the next layer, not a launch blocker for a
small TestFlight group.
