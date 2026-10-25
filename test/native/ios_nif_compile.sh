#!/usr/bin/env bash
# Compiles ios/mob_nif.m (syntax only) in each build variant an app can ship:
# debug, release, and release with the screenshot opt-in. Most of the file
# sits behind `#if !MOB_RELEASE`, and only a real compile catches a release
# table entry that names a debug-only function: MOB-504 shipped in mob 0.9.26
# because nothing built the release variant.
#
#   test/native/ios_nif_compile.sh        (from the repo root, or `make -C test/native ios-nif`)
#
# Needs Xcode (the iphoneos SDK) and an Erlang install for erl_nif.h; set
# ERL_INCLUDE to use another include dir. The Swift sources are compiled once
# to produce the MobApp-Swift.h header mob_nif.m imports.
set -euo pipefail

cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios17.0
erl_include=${ERL_INCLUDE:-$(erl -noshell -eval \
  'io:format("~s", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "include"])]), halt().')}

xcrun swiftc -sdk "$sdk" -target "$target" -module-name MobApp -parse-as-library \
  -import-objc-header ios/MobDemo-Bridging-Header.h -I"$erl_include" -Iios \
  -emit-module -emit-module-path "$out/MobApp.swiftmodule" \
  -emit-objc-header-path "$out/MobApp-Swift.h" ios/*.swift

status=0
for flags in "" "-DMOB_RELEASE=1" "-DMOB_RELEASE=1 -DMOB_ENABLE_SCREENSHOT"; do
  echo "== mob_nif.m ${flags:-(debug)}"
  # shellcheck disable=SC2086 # $flags is a list of separate -D options
  xcrun clang -fsyntax-only -fobjc-arc -fmodules -x objective-c \
    -target "$target" -isysroot "$sdk" -I"$erl_include" -Iios -I"$out" \
    $flags ios/mob_nif.m || status=1
done
exit $status
