# Rustler-on-Android: host exports RUSTLER_BEAM_LIBRARY_PATH

- Date: 2026-05-21
- Status: accepted

## Context
On Android Bionic, rustler's `nif_filler` used `dlopen(NULL)` to find `enif_*`
symbols, which fails for symbols statically linked into a sibling `.so` — so
rustler NIFs crashed at init in mob's static-link model. Our initial upstream
fix (GenericJam/rustler PR #726) used `dladdr` to self-resolve the `.so`, but
the rustler maintainer (filmor) preferred a smaller change exposing an env var
(rusterlium/rustler#733, `RUSTLER_BEAM_LIBRARY_PATH`) and did not want to
maintain the `dladdr` code path.

## Decision
`mob_beam.zig` discovers the host `.so` path via `dladdr(&mob_start_beam)` and
exports `RUSTLER_BEAM_LIBRARY_PATH` before the BEAM starts; rustler reads it to
`dlopen` the right `.so`. We adopt filmor's env-var name to stay compatible
with the version that lands upstream.

## Consequences
Rust NIFs resolve `enif_*` correctly on Bionic — verified end-to-end on a
physical arm64 device. Shipped in mob 0.6.18 (renamed from the earlier
`RUSTLER_NIF_LIB_PATH` used in 0.6.16/0.6.17).
