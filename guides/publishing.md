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
- **Keep usage strings in Info.plist** — counterintuitive but important. Don't strip `NSCameraUsageDescription` etc. just because your app doesn't use them. The framework's NIFs reference those APIs and Apple's secondary scanner will reject the build. ([why](https://hexdocs.pm/mob_dev/publishing_to_testflight.html#13-keep-usage-strings-in-infoplist-counterintuitive--read-this))
- **Register the App ID** at [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) — manual web-portal step
- **Create an Apple Distribution certificate** — Xcode → Settings → Accounts → Manage Certificates → +
- **Create an App Store provisioning profile** — at [developer.apple.com](https://developer.apple.com/account/resources/profiles/list) — bind cert + App ID
- **Install the profile** — double-click the downloaded `.mobileprovision`
- **Run** `mix mob.provision --distribution` — verifies cert + profile, generates the signing project
- **Create the App Store Connect app record** — at [appstoreconnect.apple.com](https://appstoreconnect.apple.com/apps) — pick your bundle ID from the dropdown
- **Generate an App Store Connect API key** — Team Keys, App Manager role, **download `.p8` (one-time only)**
- **Configure `mob.exs`** with the API key (see detailed guide for the exact block)

### Per-release flow

One command:

```bash
mix mob.republish --ios   # bumps CFBundleVersion, mob.release, mob.publish --ios
```

That wraps three steps that you can also run individually:

- **Bump build number** — `CFBundleVersion` (integer) must be unique
  per upload; `CFBundleShortVersionString` (semver, the public version)
  stays put.
- **`mix mob.release`** — builds `_build/mob_release/<App>.ipa`.
- **`mix mob.publish --ios`** — uploads via `xcrun altool` to App Store
  Connect.

After upload Apple processes the build for 5–15 min before it shows in
the TestFlight tab. Add testers there.

`mix mob.provision --distribution` is annual (when your App Store
profile expires) — `mob.republish` doesn't re-run it.

**Platform flag is required on `publish` and `republish`.** Mob is
intentionally platform-agnostic; pass `--ios` (works today) or
`--android` (errors with "not yet implemented" — Android publish
pipeline is on the roadmap).

## Common surprises

- **Bundle ID can't be `com.example.*`** — Apple validates the prefix
- **App ID registration is manual** — `mix mob.provision` can't auto-create
  it (Apple's API limitations under `xcodebuild`). One-time web step.
- **Distribution cert is separate from your dev cert** — Xcode Settings creates it
- **Profile names don't matter** — `mob_dev` discovers profiles by UUID, so name them however you like
- **The `.p8` API key downloads once** — Apple doesn't store the private half
- **`mix mob.publish` goes silent for several minutes** — `altool` is uploading. Use `--verbose` to see progress.
- **Bump `CFBundleVersion` before every upload** — Apple rejects re-uploads with the same build number. `mix mob.republish --ios` does this for you.
- **"Upload accepted" ≠ "build is in TestFlight"** — Apple runs a secondary scan after upload. Check email if the build doesn't appear in TestFlight after ~20 min ([why](https://hexdocs.pm/mob_dev/publishing_to_testflight.html#part-3--two-stage-validation))
- **`publish` and `republish` require explicit `--ios` or `--android`** — Mob doesn't default to either platform. Pick on every command; future-you will thank current-you when the same app ships to both stores.

## Status

The release pipeline produces App Store-validated builds end-to-end.
First proven by Air Cart Maximizer landing in TestFlight on
2026-05-02. Tested with mob 0.5.12 + mob_dev 0.3.30 on Xcode 26.

If you're on older versions and getting validator rejections, upgrade
both — the App Store-clearing fixes were spread across mob 0.5.12
(test harness compile-out) and mob_dev 0.3.27 → 0.3.30 (provisioning,
bundle stripping, full DT* / `UIDeviceFamily` /
`CFBundleSupportedPlatforms` plist keys, ditto packaging).

---

For everything else — exact button clicks at developer.apple.com, the
specific Apple errors and how to read them, what to do when a step
fails — **see the [detailed mob_dev
guide](https://hexdocs.pm/mob_dev/publishing_to_testflight.html)**.
