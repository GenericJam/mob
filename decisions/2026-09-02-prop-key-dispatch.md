# The native deserialiser resolves prop keys in one pass

- Date: 2026-09-02
- Status: accepted
- Implements: MOB-135, arising from MOB-124 measurement
- Builds on: `2026-09-01-render-instrumentation.md`

## Context

Measured on a 200-row screen (1627 nodes, 207 KB payload), `set_root` was the
largest single stage of a frame on both platforms. Splitting it open on iOS:

| phase | µs |
|---|---|
| `NSData` copy of the payload | 22 |
| `NSJSONSerialization` parse | 1345 |
| **`mob_node_from_dict`** | **5900** |
| frame-id collect + adopt | 70 |

Converting an already-parsed `NSDictionary` into `MobNode` objects cost 4.4x
what parsing the JSON did. That ratio was the anomaly.

The cause: `mob_node_from_dict` probed every prop key it knows into every node's
`props`, regardless of node type — **104 probe sites over 99 distinct keys, with
only 8 guarded by a node-type check**. At 207 KB across 1627 nodes a node
averages 127 bytes, roughly 39 of which is the `{"type","props","children"}`
skeleton, so a typical node carries three to five props and paid ~100 hashed
lookups to find them. Each probe rehashes the literal's bytes (CFString caches
nothing) and, on a hit, runs a character compare because the parsed key is a
different object from the literal.

The parse touches each byte once. The conversion did constant work per node with
no relationship to node size. That is the whole gap.

## Decision

Enumerate the node's own props once, resolve each key to a slot through a
`dispatch_once` table, and let the deserialiser read slots.

**Statement order is preserved, and that is the reason for an indexed array
rather than a switch inside the enumeration.** Prop precedence depends on order
in three places — `text` before `value` for a text field, generic `width`/`height`
before canvas, generic `corner_radius` before sheet. A switch would have
reordered those and broken them silently.

Measured, iOS simulator, same screen: `set_root` 7625 → 4040 µs, whole frame
13002 → 9403 µs. A 28% frame reduction, purely native-internal — no wire-format
change and no Elixir coordination.

## Not done here

A single-pass SAX parse straight into `MobNode`, skipping the intermediate
`NSDictionary` entirely, has a higher ceiling (an estimated 0.9-1.2 ms replacing
7.25 ms) but means owning a JSON parser — escapes, surrogate pairs, number forms,
UTF-8 validation, depth limits on adversarial input. Its marginal gain over this
change is about 1.1 ms, so it is not worth the risk yet.

Android has the same root cause by a different mechanism: no probe amplification,
but triple materialisation (Java `String`, an `org.json` tree, a second map copy
per node, then the node class). One principle fixes both — never materialise a
generic key/value object graph; scan the wire bytes once and dispatch each key by
its bytes into the typed node representation. Android remains unfixed.
