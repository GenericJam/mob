defmodule MobIap.Nif do
  @moduledoc false

  # Placeholder module for the plugin manifest's `:nifs` entry.
  #
  # The 5 IAP NIF functions (`iap_fetch_products/1`, `iap_purchase/1`,
  # `iap_restore/0`, `iap_current_entitlements/0`, `iap_manage_subscriptions/0`)
  # are registered under the existing `:mob_nif` module
  # in `src/mob_nif.erl` — following the pattern of every other Mob device API
  # (Camera, Biometric, Location, etc.).
  #
  # Native implementations live in:
  #   iOS:  `ios/mob_nif.m` → `priv/native/ios/MobIapBridge.swift` (StoreKit 2)
  #   Android: `android/jni/mob_nif.zig` → `priv/native/android/MobIapBridge.kt`
  #
  # This module exists only so the plugin manifest declaration is satisfied.
  # The NIF registration itself runs through the existing `driver_tab_*.zig`
  # static NIF table, not through this module.
end
