# Defect reports are a shipped feature, and their format is a contract

Mob apps will report their own defects — in development to the agent working on
them, and in production to whatever sink the app developer wires up. Both use
one schema.

This record exists because the format is the part that is expensive to change
later. Everything downstream parses it: the agent that triages a report, the
deduplicator, the auto-PR pipeline, and any app developer who points it at
their own endpoint. Getting the shape wrong is a migration; getting the sink
policy wrong is an incident.

## Why ship it in production and not only in dev

The usual instinct is `#if !MOB_RELEASE`, the way the screenshot NIF is gated.
That is wrong here, for a reason specific to what a defect report is: **the
interesting failures happen where no agent is watching.** A native crash on a
real user's three-year-old Android on a bad network is exactly the bug we
cannot reproduce and cannot see. Gating that out leaves the framework with
visibility only into the failures that were already easy to find.

The cost is real and is accepted: reports carry state, state carries secrets,
and shipping code that packages state is shipping code that can leak it.
That constraint drives the redaction and sink rules below rather than
disqualifying the feature.

## The sink is pluggable, and Mob is never the collector

Mob owns the **format** and the **bus**. It does not own a destination.

* **Development** — the sink is the BEAM distribution channel to the connected
  agent. A report arrives as a structured message, formatted for triage.
* **Production** — the sink is whatever the app developer configures. Their own
  endpoint, a local file, a push channel, or nothing.
* **Default** — nothing leaves the device.

Mob must not ship a default remote endpoint. A framework that silently collects
its users' users' data is a breach dressed as a feature, and no amount of
opt-out messaging fixes the default. An app developer choosing to send reports
to their own service is their decision to make about their own users; it is not
ours to make on their behalf.

## Redaction is a precondition, not a post-process

A report may carry assigns, and assigns carry secrets. This is not theoretical:
MOB-147 found a `SecureField` value crossing between screens through a reused
view identity, which means a password was sitting in the exact state a naive
report would serialise and transmit.

Rules:

* Assigns are **excluded by default**. A screen opts individual keys in.
* A value from a node marked secure is never included, opt-in or not.
* Redaction happens **before** the report leaves the reporting process, not at
  the sink. A report that reaches a sink unredacted has already failed.
* Every report carries `"redaction": "applied" | "none"`, and `"none"` is only
  legal for a report that provably contains no application state.

## The format

`schema` is the compatibility contract. Consumers must ignore unknown fields
and must refuse a `schema` major they do not recognise.

```json
{
  "schema": "mob.defect/1",
  "id": "01JBQ7...",
  "fingerprint": "sha256:9f2c...",
  "kind": "native_crash",
  "severity": "fatal",
  "detected_at": "2026-09-04T22:11:03.418Z",
  "owner": "mob",
  "redaction": "applied",

  "build": {
    "mob": "0.7.39",
    "mob_dev": "0.6.33",
    "app": "1.4.0",
    "commit": "0d38835",
    "dirty": false,
    "otp": "29",
    "elixir": "1.20.1",
    "loaded_md5": { "MobPluginDemo.HomeScreen": "a1b2..." }
  },

  "device": {
    "platform": "ios",
    "os": "26.4",
    "model": "iPhone SE (3rd generation)",
    "simulator": false,
    "locale": "en_CA",
    "scale": 3.0
  },

  "evidence": { },

  "repro": {
    "available": true,
    "minimized": true,
    "steps": [ ]
  }
}
```

### `kind`, and what `evidence` holds for each

| `kind` | source | `evidence` carries |
|---|---|---|
| `native_crash` | signal handler, MetricKit, tombstone | stack, signal, thread |
| `beam_crash` | supervisor report | exit reason, stacktrace, screen module |
| `anr` / `oom` / `user_kill` | `ApplicationExitInfo` on next boot | OS reason, trace when attached |
| `invariant` | runtime invariant registry | invariant name, observed vs expected |
| `divergence` | differential iOS/Android run | fixture, both trees, first differing node |
| `deploy_mismatch` | deployment attestation | expected vs loaded hashes |
| `perf_regression` | RenderStats against a baseline | metric, baseline, observed, sample size |

`evidence` is the only kind-specific part. Everything above it is stable across
kinds, so a consumer can triage, dedupe and attribute without knowing what
`kind` means.

### `owner` is the routing decision

`mob` | `mob_dev` | `mob_new` | `plugin:<name>` | `app` | `unknown`

This field is what lets one bus serve two purposes. Mob-owned defects are
eligible for the auto-PR pipeline. App-owned defects are **telemetry we read
and never act on** — they tell us how Mob is actually being used and misused in
the field, which is insight available no other way, but we cannot and must not
open pull requests in someone else's repository.

`unknown` is a legitimate answer and must not be guessed away. A
confidently-wrong owner sends a real defect to a repo that cannot fix it.

### `fingerprint` is for grouping, `id` is for identity

`id` is unique per occurrence. `fingerprint` is a stable hash over the
defect-defining fields only — invariant name, normalised stack, owner, implicated
source location — and deliberately excludes timestamps, device identity and
build version, so the same defect groups across devices and releases. One
thousand occurrences of one bug must be one triage item.

## What consumes this

* **Dev** — formatted for the agent as a triage summary: what broke, who owns
  it, whether it reproduces, and the suggested next action, which is normally
  "write the failing test first."
* **Auto-PR** — gated on `repro.available && repro.minimized && owner != "app"`,
  and on a regression test that fails before the fix and passes after. Draft PRs
  only. This gate is not negotiable: a queue of plausible-looking PRs nobody
  trusts is worse than no automation.
* **App developers** — the same JSON, at their own sink, for their own users.

## Consequences accepted

* Report-packaging code ships in release builds, so it is attack surface and
  must be treated as such — bounded sizes, no unbounded recursion over
  user-controlled trees, no execution of anything in a report.
* Ring buffers and fingerprinting cost memory and cycles in production. Budget
  them explicitly rather than discovering the cost on a low-end device.
* The schema is a public contract the moment an app developer parses it.
  Additive changes only within a major.
