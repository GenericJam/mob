# Publishing a Mob app to the App Store / TestFlight

iOS publishing is driven by `mob_dev`. This page is a quick orientation;
the **detailed step-by-step (with screenshots, troubleshooting, and
all the Apple-portal gotchas) lives in `mob_dev`**:

> **[Full guide: Publishing to TestFlight (iOS)](https://hexdocs.pm/mob_dev/publishing_to_testflight.html)**

## TL;DR

iOS publishing is two phases — a one-time setup, then a three-command
release loop you'll do for every build.

### One-time setup (per app)

- **Pick a real bundle ID** — `com.example.*` won't fly with Apple
- **Update `ios/Info.plist`** — bundle ID, display name, semver version
- **Update `android/app/build.gradle`** — `applicationId` to match
- **Strip unused permissions** from Info.plist (camera/mic/location/etc. that the framework template scaffolds but your app may not use)
- **Register the App ID** at [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) — manual web-portal step
- **Create an Apple Distribution certificate** — Xcode → Settings → Accounts → Manage Certificates → +
- **Create an App Store provisioning profile** — at [developer.apple.com](https://developer.apple.com/account/resources/profiles/list) — bind cert + App ID
- **Install the profile** — double-click the downloaded `.mobileprovision`
- **Run** `mix mob.provision --distribution` — verifies cert + profile, generates the signing project
- **Create the App Store Connect app record** — at [appstoreconnect.apple.com](https://appstoreconnect.apple.com/apps) — pick your bundle ID from the dropdown
- **Generate an App Store Connect API key** — Team Keys, App Manager role, **download `.p8` (one-time only)**
- **Configure `mob.exs`** with the API key (see detailed guide for the exact block)

### Per-release flow

```bash
mix mob.provision --distribution   # idempotent; only when profile expires
mix mob.release                    # builds _build/mob_release/<App>.ipa
mix mob.publish                    # uploads to App Store Connect (TestFlight)
```

After upload Apple processes the build for 5–15 min before it shows in
the TestFlight tab. Add testers there.

## Common surprises

- **Bundle ID can't be `com.example.*`** — Apple validates the prefix
- **App ID registration is manual** — `mix mob.provision` can't auto-create
  it (Apple's API limitations under `xcodebuild`). One-time web step.
- **Distribution cert is separate from your dev cert** — Xcode Settings creates it
- **Profile names don't matter** — `mob_dev` discovers profiles by UUID, so name them however you like
- **The `.p8` API key downloads once** — Apple doesn't store the private half
- **`mix mob.publish` goes silent for several minutes** — `altool` is uploading. Use `--verbose` to see progress.

## Known limitation (mob 0.5.10)

The release pipeline produces a signed `.ipa` and uploads it to App
Store Connect successfully, but Apple's automated validator currently
rejects the build because Mob bundles the OTP runtime tree (containing
`.so`/`.a` files Apple doesn't allow) and uses test-harness NIFs that
reference private UIKit selectors.

The build IS sideload-able to a connected device via Xcode for ad-hoc
testing.

The framework work to clear App Store validation (switch to statically
linked `libbeam.a`, compile out test-harness NIFs in release mode, fix
Info.plist + IPA packaging) is tracked separately. See the [detailed
guide's "Known limitation"
section](https://hexdocs.pm/mob_dev/publishing_to_testflight.html#known-limitation-app-store-validator-rejects-the-bundle)
for the specific errors and the static-link approach.

---

For everything else — exact button clicks at developer.apple.com, the
specific Apple errors and how to read them, what to do when a step
fails — **see the [detailed mob_dev
guide](https://hexdocs.pm/mob_dev/publishing_to_testflight.html)**.
