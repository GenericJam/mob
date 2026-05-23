%{
  name: :mob_iap,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "In-App Purchase — consumables, non-consumables, and subscriptions via StoreKit 2 (iOS) and Play Billing 7 (Android)",

  nifs: [
    %{module: MobIap.Nif, native_dir: "priv/native"}
  ],

  android: %{
    gradle_deps: ["com.android.billingclient:billing:7.0.0"],
    permissions: ["com.android.vending.BILLING"],
    bridge_kt: "priv/native/android/MobIapBridge.kt",
    jni_source: "priv/native/android/jni/iap.c"
  },

  ios: %{
    swift_files: ["priv/native/ios/MobIapBridge.swift"],
    frameworks: ["StoreKit"],
    plist_keys: %{}
  },

  screens: [
    %{module: MobIap.StoreScreen, default_route: "/iap/store"},
    %{module: MobIap.SubscriptionScreen, default_route: "/iap/subscriptions"}
  ],

  settings: %{
    schema: [
      %{key: :auto_verify_receipts, type: :boolean, default: true},
      %{key: :verification_endpoint, type: :string, default: ""}
    ],
    editor_screen: MobIap.SettingsScreen
  },

  config: %{
    verify: %{
      timeout_ms: 10_000,
      retry_count: 3
    }
  }
}
