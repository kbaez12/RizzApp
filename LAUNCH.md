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
| Final **app name** | RizzApp (working title) | Xcode display name, App Store Connect, RevenueCat |
| **Bundle ID** | `com.placeholder.rizzapp` | `project.yml`, Apple Developer, App Store Connect, RevenueCat, RevenueCat products |
| **App icon** | none | 1024×1024 PNG, no alpha, plus the Xcode asset catalog |
| **Privacy Policy URL** | `https://rizzapp.example.com/privacy` | `LegalLinks.swift`, App Store Connect, paywall |
| **Terms of Use URL** | `https://rizzapp.example.com/terms` | `LegalLinks.swift`, paywall |
| **Support URL or email** | `mailto:support@rizzapp.example.com` | `LegalLinks.swift`, App Store Connect |
| Apple Developer **Team ID** | — | Xcode signing |
| OpenAI **API key** | — | Supabase secret `OPENAI_API_KEY` |
| RevenueCat **public SDK key** | `appl_PASTE_…` | `APIConfig.swift` |
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

1. Signing & Capabilities → your Team. Change the bundle ID from
   `com.placeholder.rizzapp` in `project.yml` and regenerate, or edit it
   in the target.
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
   `https://github.com/RevenueCat/purchases-ios` (5.x) → product
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
publishable/anon key. Paste them into `APIConfig.localDevelopment` and
set `AppConfig.serviceMode = .liveDevelopment`.

Hosted project:

```bash
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets set OPENAI_MODEL=gpt-5.6-terra
supabase secrets set REVENUECAT_WEBHOOK_SECRET=a-long-random-string
supabase functions deploy generate
supabase functions deploy usage
supabase functions deploy revenuecat-webhook
```

Fill `APIConfig.remoteDevelopment` from Dashboard → Settings → API
(project URL + **publishable** key). Never put the service-role or
secret key in the iOS app.

Confirm `DEV_ERROR_SIMULATION` is **unset** on the hosted project.

Webhook URL to give RevenueCat:

```
https://YOUR-PROJECT-REF.supabase.co/functions/v1/revenuecat-webhook
```

Authorization header value = the `REVENUECAT_WEBHOOK_SECRET` you set.

---

## 3. OpenAI

1. Create an API key at platform.openai.com. Restrict it if possible.
2. Put it **only** in Supabase secrets (`OPENAI_API_KEY`).
3. Confirm model access to `gpt-5.6-terra` (or change `OPENAI_MODEL`).
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
   - Subscription Group: e.g. `plus`
   - Product `plus_monthly` — $6.99 / 1 month
   - Product `plus_yearly` — $49.99 / 1 year
4. Localization for each product (display name + description).
5. Submit the subscription group for review with the first build
   (or as a standalone subscription review, depending on current
   ASC flow).

### RevenueCat

1. Create a project, iOS app, bundle ID matching ours.
2. Upload the In-App Purchase Key (p8) from App Store Connect → Users
   and Access → Integrations → In-App Purchase.
3. Products: import `plus_monthly` and `plus_yearly`.
4. Entitlement: `plus` — attach both products.
5. Offering: `default`
   - Package `$rc_monthly` → `plus_monthly`
   - Package `$rc_annual` → `plus_yearly`
6. Public SDK key (`appl_…`) → `APIConfig.revenueCatPublicKey`.
7. Webhooks → the Supabase URL above. Authorization header = the
   secret. The app user ID is our installation UUID, which is how
   the webhook maps to the quota row. **Do not** enable anonymous
   aliases that would replace that ID.
8. Sandbox testers: App Store Connect → Users and Access → Sandbox.

The client never tells the backend it is premium. Only the webhook
changes `installations.tier`.

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
> We do not create accounts. We do not store conversations. Free users
> get 5 analyses; Plus is an auto-renewing subscription (monthly /
> yearly) via StoreKit. Restore Purchases is on the paywall and in
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
- [ ] `AppConfig.serviceMode = .liveDevelopment` (or a production
      equivalent) pointing at the **hosted** Supabase project
- [ ] OpenAI secret set; a real generation succeeds on device
- [ ] RevenueCat public key set; sandbox purchase of monthly works
- [ ] Sandbox purchase of yearly works
- [ ] Restore Purchases works
- [ ] Webhook received `INITIAL_PURCHASE` and the installation row
      flipped to `plus` (check in Supabase Table Editor)
- [ ] Free quota: 5 → paywall
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
- Publishable-key validation (`@supabase/server` `auth: "publishable"`)
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
