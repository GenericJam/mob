# 0.7.0 release plan — the plugin-extraction breaking major

Status: PREPARED, not executed. Versions are drafted UNRELEASED; nothing
is on Hex; per RELEASE.md no bump happens without explicit permission.

## What ships

| Package | From | Contents |
|---|---|---|
| mob 0.7.0 | 0.6.26 | plugin runtime (tiers 0-4, spec-v2, composites, styles), BREAKING capability strips (see CHANGELOG) |
| mob_dev 0.6.0 | 0.5.17 | plugin/style build infra, doctor checks, driver_tab auto-regen, dep-detection fix |
| mob_new 0.x bump | — | stripped templates, dotfile fix, baseline switcher |
| mob_bluetooth, mob_location, mob_camera, mob_photos, mob_biometric, mob_notify, mob_scanner 0.1.0 | new | the extracted capability plugins |
| mob_themes 0.1.0 | new | five preset themes (style package) |
| mob_ash 0.1.0 | new | Ash-driven generated screens (spec-v2) |
| mob_push 0.2.x | 0.2.1 | already published; contract fixtures landed (patch bump optional) |

## Sequence (order matters — deps point down the list)

1. **Kevin: green-light versions** (suggested above; RELEASE.md rule).
2. **Push masters to origin**: mob, mob_dev, mob_new (currently local-only;
   plugin repos already pushed). Pre-push hooks run the full preflight.
3. **Kevin: flip plugin repos public** (currently private:
   location/bluetooth/camera/screencast/notify/photos/biometric/scanner/
   themes/ash) and **set HEX_API_KEY** on every repo that should publish
   (Settings → Secrets → Actions).
4. **Publish mob 0.7.0**: bump mix.exs on master, push — release.yml tags,
   creates the GitHub Release, publishes (preflight: full suite runs via
   the pre-push hook because mix.exs changed).
5. **Publish mob_dev + mob_new** (their generated apps/templates reference
   the new plugin packages by name only — no hard dep on them).
6. **Flip the plugin/style packages' `{:mob, path: "../mob"}` →
   `{:mob, "~> 0.7"}`** (one commit each; the mix.exs change triggers each
   repo's release.yml on push → Hex). The `{:mob_dev, path:, only: :test}`
   dev dep can stay (test-only deps don't ship in the package) or flip to
   `"~> 0.6"` once mob_dev is up.
7. **Publish order within the packages**: mob_camera before mob_scanner
   (scanner's docs/README direct users to activate camera). Others are
   independent.
8. **Post-publish smoke**: `mix mob.new smoke_app` from the PUBLISHED
   archive + add one Hex plugin + `mix mob.doctor` + an Android build.

## Known-open items deliberately NOT blocking

- Stale-BEAM overlay on device (`Documents/otp/<app>` keeps hot-pushed
  beams across installs; stripped modules stay loadable in the DEV loop —
  fresh user installs are unaffected). Fix tracked: prune the overlay on
  `--native` deploy.
- Live push end-to-end (real APNs/FCM creds + mob_push) — mob_notify's
  EXTRACTION.md Stage 4 remainder.
- iPhone dist-probe for the latest build (scanner/ash/kit/themes are
  installed on the SE; pure-Elixir, Android-verified; the probe needs the
  unplug/relaunch dance).
- Native style tier (cascade), plugin native-view capability, generator
  lane (`mix mob.gen.component`), Android biometric un-degrade
  (androidx.biometric 1.2.x) — all post-release features.
- code_to_cloud: migrate `Mob.Theme.ObsidianGlass` → `MobThemes.ObsidianGlass`
  when it bumps mob.

## Manual-step checklist for Kevin (the irreducible bits)

- [ ] Version green-light (mob 0.7.0 + the table above)
- [ ] `git push` permission for mob / mob_dev / mob_new masters
- [ ] Repos public (10 ×) — or publish from private (Hex doesn't care;
      docs links will 404 until public)
- [ ] HEX_API_KEY secret per publishing repo
- [ ] (optional) reserve the package names on Hex beforehand
