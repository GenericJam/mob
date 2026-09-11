# Fingerprint and evidence are separate inputs to a defect

- Date: 2026-09-11
- Status: accepted

## Context

`Mob.Defect.Capsule.new/1` takes both a `fingerprint_key` and an
`evidence` map, and the two overlap: `emit_invariant_violation/1` puts
`%{invariant, screen}` in the key and `%{invariant, screen, at, details}`
in evidence. That is deliberate, but it looks redundant, and the temptation
when adding a new detector is to fold them into one map. This record exists
to say why they are two.

The single-map version is:

    Capsule.new(kind: :invariant, owner: :mob, severity: :critical,
                evidence: %{invariant: name, screen: screen, at: at, details: details})

...with the fingerprint computed over the whole `evidence` map. Simpler to
write. Reasonable-looking. Wrong in a way that only appears on the second
release.

## Decision

The **fingerprint** is computed over `kind`, `owner`, and the
`fingerprint_key` map. Nothing in `evidence` beyond what the caller
explicitly put in `fingerprint_key` participates.

Callers put in the key exactly what identifies the defect *class* — the
invariant name plus the screen, the fixture plus the divergence reason plus
the path — and nothing that describes the individual occurrence.

## Consequences

**Enrichment does not shatter groups.** Adding an `os_locale` field to the
evidence of an invariant capsule in mob 0.9 does not split every existing
triage item in two, because that field is not in the key. A defect that
occurred in 0.8 and 0.9 stays one row on the triage list. Without this
split, the fingerprint would change the moment we noticed a useful new
detail to attach.

**Two occurrences that agree in key but disagree in evidence still group.**
This is the point. A leaked-component invariant that lists three pids on
one device and four on another is still the same class of defect. The
fingerprint says so; the class row keeps the first capsule's evidence to
avoid presenting a moving target; the recent-ring holds the raw
occurrences for anyone drilling in.

**Callers must be disciplined about the key.** If a detector puts the
`monotonic_us` timestamp in the key, every occurrence gets a new
fingerprint and dedup does not work. If it puts an empty map, every defect
of that `kind` collides onto one row. Both failure modes are visible
immediately — a `classes/1` listing that grows unboundedly, or one that
stays at one row while occurrences climb. The mapping to construct the
key is centralised in `Mob.Defect` so a caller does not need to invent
one; new detectors add a function there and inherit the discipline.

The kind-of-thing that goes in `fingerprint_key` is a defect class
identifier. Anything derivable at debug time from a stack trace or a
module name qualifies; anything that changes between two invocations of
the same defect does not. The moduledoc on `Mob.Defect.Capsule` lists
what is excluded by construction (`id`, `detected_at`, `build.*`,
`device.*`) so this discipline shows up in the type.

## Alternatives considered

**One-map fingerprint over `evidence`.** Ruled out: enriching evidence
changes the fingerprint, so improving the report shatters the triage
history the report was meant to build.

**Include the full first capsule in the class row and hash *its* stable
subset.** Two problems. First, the "stable subset" needs the same key
definition anyway, so the split moves rather than disappears. Second,
recomputing hashes on every emit is wasted work: the caller already
knows what defines the defect, and asking them for a small map is
cheaper than asking every reader to recompute one from a big struct.
