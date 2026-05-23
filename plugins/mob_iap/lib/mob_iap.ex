defmodule MobIap do
  @moduledoc """
  In-App Purchase for iOS (StoreKit 2) and Android (Play Billing 7).

  All calls are fire-and-forget — results arrive as `handle_info`
  messages tagged `{:iap, ...}`. Same async pattern as `Mob.Camera`,
  `Mob.Biometric`, and `Mob.Location`.

  ## Setup

  Add `mob_iap` to your deps and `:mob_iap` to `config :mob, :plugins`
  in your app config. The plugin manifest registers the native bridges,
  permissions, and UI screens automatically.

  ### On-device receipt verification (StoreKit 2)

  StoreKit 2 transactions arrive as signed JWTs. The native side
  verifies the signature chain and bundle ID before returning the
  transaction. For subscriptions and non-consumables, server-side
  verification is still recommended.

  ## Events

  All events arrive in `c:Mob.Screen.handle_info/2`. Payloads for products,
  transactions, and transaction lists are JSON binaries — use
  `MobIap.decode_products!/1`, `MobIap.decode_transaction!/1`, and
  `MobIap.decode_transactions!/1` to convert them to structs.

      # Products fetched from the store (json is a binary — decode with decode_products!/1)
      {:iap, :products, json}

      # Store connection error (network, account issue, etc.)
      {:iap, :products_failed}

      # Purchase completed — unlock content now (json is a binary — decode with decode_transaction!/1)
      {:iap, :purchased, json}

      # Purchase failed
      {:iap, :purchase_failed}

      # User cancelled the purchase dialog
      {:iap, :cancelled}

      # Purchase pending — e.g. parental approval required (json is a binary)
      {:iap, :purchase_pending, json}

      # Restored purchases — re-unlock previously purchased items (json is a binary)
      {:iap, :restored, json}

      # Current entitlements — active subs + owned non-consumables (json is a binary)
      {:iap, :entitlements, json}

      # Restore failed (network or store error)
      {:iap, :restore_failed}

      # Entitlements query failed
      {:iap, :entitlements_failed}

      # Server-side verification result
      {:iap, :verified, transaction_id, :valid | {:invalid, reason}}

  ## Examples

      def handle_info({:iap, :products, json}, socket) do
        products = MobIap.decode_products!(json)
        {:noreply, Mob.Screen.assign(socket, :products, products)}
      end

      def handle_info({:iap, :purchased, json}, socket) do
        tx = MobIap.decode_transaction!(json)
        # Unlock content for tx.product_id
        unlock(socket, tx)
        {:noreply, socket}
      end

      def handle_info({:iap, :cancelled}, socket) do
        {:noreply, socket}
      end

      def handle_info({:iap, :purchase_failed}, socket) do
        Logger.warning("Purchase failed")
        {:noreply, socket}
      end
  """

  @doc """
  Fetch products from the store.

  Product IDs are the identifiers configured in App Store Connect / Play Console.
  Returns localized pricing, descriptions, and subscription metadata.

      MobIap.fetch_products(socket, [:premium, :coins_100])
  """
  @spec fetch_products(Mob.Socket.t(), [atom()]) :: Mob.Socket.t()
  def fetch_products(socket, product_ids) when is_list(product_ids) do
    try do
      :mob_nif.iap_fetch_products(Enum.map(product_ids, &Atom.to_string/1))
    catch
      :error, :undef -> :ok
    end

    socket
  end

  @doc """
  Initiate a purchase for a product.

  Shows the native purchase dialog. The user can authenticate with
  Touch ID / Face ID and confirm or cancel. The result arrives as
  `{:iap, :purchased, tx}` or `{:iap, :cancelled}`.

      MobIap.purchase(socket, :premium)
  """
  @spec purchase(Mob.Socket.t(), atom()) :: Mob.Socket.t()
  def purchase(socket, product_id) when is_atom(product_id) do
    try do
      :mob_nif.iap_purchase(Atom.to_string(product_id))
    catch
      :error, :undef -> :ok
    end

    socket
  end

  @doc """
  Restore previously purchased non-consumables and subscriptions.

  Required by App Store guidelines — provide a visible "Restore Purchases"
  button in your UI. No-op on Android if `queryPurchasesAsync` catches
  everything.

      MobIap.restore(socket)
  """
  @spec restore(Mob.Socket.t()) :: Mob.Socket.t()
  def restore(socket) do
    try do
      :mob_nif.iap_restore()
    catch
      :error, :undef -> :ok
    end

    socket
  end

  @doc """
  Fetch current entitlements — active subscriptions and owned non-consumables.

  Uses StoreKit 2 `Transaction.currentEntitlements` on iOS,
  `BillingClient.queryPurchasesAsync` on Android. Call on app launch
  to re-verify entitlements after backgrounding.

      MobIap.current_entitlements(socket)
  """
  @spec current_entitlements(Mob.Socket.t()) :: Mob.Socket.t()
  def current_entitlements(socket) do
    try do
      :mob_nif.iap_current_entitlements()
    catch
      :error, :undef -> :ok
    end

    socket
  end

  @doc """
  Open the OS-level subscription management UI.

  iOS: opens Settings → Subscriptions.
  Android: opens Play Store → Subscriptions for this app.

      MobIap.manage_subscriptions(socket)
  """
  @spec manage_subscriptions(Mob.Socket.t()) :: Mob.Socket.t()
  def manage_subscriptions(socket) do
    try do
      :mob_nif.iap_manage_subscriptions()
    catch
      :error, :undef -> :ok
    end

    socket
  end

  @doc """
  Verify a transaction receipt through the configured server endpoint.

  Performs an async HTTP POST to `verification_endpoint` (set via plugin
  settings or `Application.put_env(:mob_iap, :verification_endpoint, url)`).
  Posts `{tx_id, receipt: receipt_data}` as JSON.

  Result arrives as `{:iap, :verified, tx_id, result}` where result is
  `:valid` or `{:invalid, reason}`.

  If no endpoint is configured, falls back to the no-op NIF stub.

      # Configure endpoint in config/runtime.exs or via SettingsScreen
      Application.put_env(:mob_iap, :verification_endpoint,
                          "https://api.example.com/verify-receipt")

      MobIap.verify(socket, tx.id, tx.original_json)

      # In handle_info/2:
      def handle_info({:iap, :verified, tx_id, :valid}, socket) do
        {:noreply, socket}
      end
  """
  @spec verify(Mob.Socket.t(), String.t(), String.t()) :: Mob.Socket.t()
  def verify(socket, transaction_id, receipt_data) do
    endpoint = Application.get_env(:mob_iap, :verification_endpoint, "")

    if endpoint == "" do
      send(self(), {:iap, :verified, transaction_id, {:invalid, "no_endpoint_configured"}})
    else
      caller = self()

      Task.start(fn ->
        result =
          try do
            body = Jason.encode!(%{tx_id: transaction_id, receipt: receipt_data})

            case :httpc.request(
                   :post,
                   {String.to_charlist(endpoint), [], ~c"application/json", body},
                   [connect_timeout: 5_000, timeout: 10_000],
                   []
                 ) do
              {:ok, {{_, 200, _}, _headers, resp_body}} ->
                case Jason.decode(IO.iodata_to_binary(resp_body)) do
                  {:ok, %{"valid" => true}} -> :valid
                  {:ok, %{"valid" => false, "reason" => reason}} -> {:invalid, reason}
                  _ -> {:invalid, "unrecognized_response"}
                end

              {:ok, {{_, code, _}, _headers, _body}} ->
                {:invalid, "http_#{code}"}

              {:error, reason} ->
                {:invalid, inspect(reason)}
            end
          rescue
            e -> {:invalid, Exception.message(e)}
          end

        send(caller, {:iap, :verified, transaction_id, result})
      end)
    end

    socket
  end

  # ── JSON decode helpers ────────────────────────────────────────────────
  # The native bridges send product/transaction data as JSON binaries.
  # Use these helpers in handle_info to decode structured messages.

  @product_types %{
    "consumable" => :consumable,
    "non_consumable" => :non_consumable,
    "auto_renewable" => :auto_renewable,
    "non_renewing" => :non_renewing
  }

  @ownership_types %{
    "purchased" => :purchased,
    "family_shared" => :family_shared
  }

  @environments %{
    "production" => :production,
    "sandbox" => :sandbox
  }

  @doc """
  Decode a JSON product list from `{:iap, :products, json}`.

      def handle_info({:iap, :products, json}, socket) do
        products = MobIap.decode_products!(json)
        {:noreply, assign(socket, :products, products)}
      end
  """
  @spec decode_products!(binary()) :: [MobIap.Product.t()]
  def decode_products!(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Enum.map(&map_to_product/1)
  end

  @doc """
  Decode a transaction list JSON from `{:iap, :entitlements, json}`
  or `{:iap, :restored, json}`.
  """
  @spec decode_transactions!(binary()) :: [MobIap.Transaction.t()]
  def decode_transactions!(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Enum.map(&map_to_transaction/1)
  end

  @doc """
  Decode a single transaction JSON from `{:iap, :purchased, json}`.
  """
  @spec decode_transaction!(binary()) :: MobIap.Transaction.t()
  def decode_transaction!(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> map_to_transaction()
  end

  # Convert JSON string keys to atoms for Product struct
  defp map_to_product(map) do
    %MobIap.Product{
      id: map["id"],
      display_name: map["display_name"],
      description: map["description"],
      price: map["price"],
      price_amount: map["price_amount"],
      currency_code: map["currency_code"],
      type: Map.get(@product_types, map["type"], :consumable),
      subscription_period: map["subscription_period"],
      introductory_offer: map["introductory_offer"],
      trial_period: map["trial_period"]
    }
  end

  # Convert JSON string keys to atoms for Transaction struct
  defp map_to_transaction(map) do
    %MobIap.Transaction{
      id: map["id"],
      product_id: map["product_id"],
      purchase_date: map["purchase_date"],
      expires_date: map["expires_date"],
      original_json: map["original_json"],
      is_upgraded: map["is_upgraded"] == 1,
      ownership_type: Map.get(@ownership_types, map["ownership_type"], :purchased),
      environment: Map.get(@environments, map["environment"], :production)
    }
  end
end
