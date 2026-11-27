# Security policy

## Reporting a vulnerability

Email **genericjam@gmail.com** with `[mob security]` in the subject. Please
don't open a public issue, pull request or discussion for a vulnerability.

Include what you can of:

- the mob version (or commit) and the platform: Android or iOS, device or
  simulator/emulator, OS version;
- how an attacker gets their input to the vulnerable code (a deep link, a push
  notification, a WebView message, a network peer, another app on the device);
- steps or a proof of concept that reproduce it;
- what it lets the attacker do.

The same address covers the related packages I maintain: `mob_dev`, `mob_new`
and the `mob_*` plugins published from
[github.com/GenericJam](https://github.com/GenericJam). If a problem spans
several of them, send one report and I'll coordinate the fixes.

## What happens next

- I acknowledge reports within 7 days.
- I confirm or rule out the issue, then fix it in a new release on Hex.
- Once the fix is published, I publish a GitHub security advisory that credits
  you, unless you'd rather not be named.
- Please keep the details private until the fix is released, or for 90 days
  after your report, whichever comes first. If a fix needs longer, I'll tell you
  why and we'll agree on a date.

## Supported versions

Mob is pre-1.0. Security fixes go into the next release only, and older versions
don't get backports. Upgrade to the latest release on
[Hex](https://hex.pm/packages/mob) to pick up a fix.

## Scope

Mob embeds the BEAM in Android and iOS apps. Its Elixir code, the NIF and the
native bridges (`android/jni/`, `ios/`) sit between the app and the outside
world, so the boundaries that matter are where outside data enters the app.

**In scope:**

- Untrusted input: deep links, notification payloads, WebView messages, data
  from the network or from devices. This covers how mob routes and decodes that
  input, how it stores it, and how it passes it to native code.
- Memory safety in the NIF and the native bridges. A crash or memory corruption
  counts when outside data can trigger it, even if trusted app code makes the
  call.
- Erlang distribution used for development:
  - a listener that is reachable when it shouldn't be;
  - a leaked distribution cookie, or a fallback to a public or predictable one;
  - development access left enabled in a release build.

  Binding to loopback is not authentication: other apps on the same device can
  connect to it. On a physical iPhone, a development build's distribution is
  reachable from the local network by design and is protected by the app's
  private cookie; getting in without that cookie is a vulnerability. The
  connection is not encrypted, so development builds assume a local network you
  trust; an attacker who can intercept traffic on it is outside that protection.
- App data exposed through files, screen state, logs or crash output.

**Not vulnerabilities on their own:**

- The app's own Elixir code, or a plugin the developer activated, running with
  the app's permissions. Both are trusted code by design (see
  [`MOB_PLUGIN_SECURITY.md`](MOB_PLUGIN_SECURITY.md)). A way around the plugin
  signature or trust checks *is* a vulnerability; those checks live in
  `mob_dev`.
- An authenticated distribution peer running arbitrary code. That access is the
  point of distribution.
- Bugs in Erlang/OTP, Elixir, Android, iOS or a third-party library. Report
  those upstream. Do tell me if mob ships an affected version and needs to move
  to a fixed one. Mob builds its own OTP runtimes with a few patches (in
  `mob_dev`'s `scripts/release/`); a bug those patches or our build settings
  introduce belongs here.
