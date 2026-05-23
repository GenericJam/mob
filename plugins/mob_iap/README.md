# mob_iap — In-App Purchase plugin for Mob

StoreKit 2 (iOS) and Play Billing 7.0 (Android) for Mob apps.

## Installation

Add `:mob_iap` to your deps and activate it in your config:

```elixir
# mix.exs
defp deps do
  [
    {:mob_iap, "~> 0.1"}
  ]
end

# config/runtime.exs
config :mob, :plugins, [:mob_iap]
```

## Product types

| Type | iOS | Android | Description |
|---|---|---|---|
| `:consumable` | ✅ | ✅ | One-time purchasable, consumed after use (gems, coins) |
| `:non_consumable` | ✅ | ✅ | One-time purchasable, permanent (unlock, remove ads) |
| `:auto_renewable` | ✅ | ✅ | Auto-renewing subscription |
| `:non_renewing` | ✅ | ✅ | Non-renewing subscription |

## API

```elixir
# Fetch products from the store
MobIap.fetch_products(socket, [:premium, :coins_100])

# Initiate a purchase
MobIap.purchase(socket, :premium)

# Restore previous purchases
MobIap.restore(socket)

# Get current entitlements (active subs + owned non-consumables)
MobIap.current_entitlements(socket)

# Open OS subscription management
MobIap.manage_subscriptions(socket)

# Server-side receipt verification
MobIap.verify(socket, tx.id, tx.original_json)
```

All calls are fire-and-forget — results arrive as `handle_info` messages.
JSON payloads must be decoded with the provided helpers:

```elixir
def handle_info({:iap, :products, json}, socket) do
  products = MobIap.decode_products!(json)
  {:noreply, assign(socket, :products, products)}
end

def handle_info({:iap, :purchased, json}, socket) do
  tx = MobIap.decode_transaction!(json)
  unlock_content(socket, tx.product_id)
  {:noreply, socket}
end

def handle_info({:iap, :cancelled}, socket) do
  {:noreply, socket}
end
```

## Events

| Event | Payload |
|---|---|
| `{:iap, :products, json}` | Product list as JSON binary — decode with `MobIap.decode_products!/1` |
| `{:iap, :products_failed}` | Store unavailable |
| `{:iap, :purchased, json}` | Transaction JSON — decode with `MobIap.decode_transaction!/1` |
| `{:iap, :purchase_failed}` | Purchase failed |
| `{:iap, :cancelled}` | User cancelled |
| `{:iap, :purchase_pending, json}` | Pending (e.g. parental approval) — decode with `MobIap.decode_transaction!/1` |
| `{:iap, :restored, json}` | Restored transactions — decode with `MobIap.decode_transactions!/1` |
| `{:iap, :restore_failed}` | Restore failed |
| `{:iap, :entitlements, json}` | Active entitlements — decode with `MobIap.decode_transactions!/1` |
| `{:iap, :entitlements_failed}` | Entitlements query failed |
| `{:iap, :verified, tx_id, result}` | Verification result (`:valid` or `{:invalid, reason}`) |

## Screens

```elixir
# Product storefront
Mob.Socket.push_screen(socket, MobIap.StoreScreen,
  product_ids: [:premium, :coins_100],
  title: "Shop")

# Active subscriptions management
Mob.Socket.push_screen(socket, MobIap.SubscriptionScreen)

# Plugin settings
Mob.Socket.push_screen(socket, MobIap.SettingsScreen)
```

## Receipt verification

StoreKit 2 transactions include a signed JWT in `original_json`. For
server-side verification:

1. Set `verification_endpoint` in plugin settings (or via app config)
2. Call `MobIap.verify/3` with the transaction ID and receipt data
3. The configured endpoint receives a POST with the receipt JWS
4. Verify against Apple's `/verifyReceipt` or Google's
   `purchases.products.get`

## Architecture

```
MobIap (Elixir) → :mob_nif (NIF) → MobIapBridge (native) → Store
  ◦ iap_fetch_products        ◦ mob_nif.zig/erl         ◦ Swift (StoreKit 2)
  ◦ iap_purchase                                         ◦ Kotlin (Play Billing)
  ◦ iap_restore              Results flow back as
  ◦ iap_current_entitlements enif_send → handle_info
  ◦ iap_manage_subscriptions
```

The native bridges reside in `priv/native/ios/` and `priv/native/android/`.
They're merged into the host app's native build by the mob_dev pipeline.
