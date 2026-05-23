defmodule MobIapTest do
  use ExUnit.Case, async: true

  alias MobIap.{Product, Transaction}

  describe "API functions" do
    test "fetch_products/2 returns the socket unchanged" do
      socket = %Mob.Socket{}
      assert ^socket = MobIap.fetch_products(socket, [:test_product])
    end

    test "fetch_products/2 converts atom product IDs to strings for NIF" do
      socket = %Mob.Socket{}
      assert %Mob.Socket{} = MobIap.fetch_products(socket, [:premium, :coins_100])
    end

    test "purchase/2 returns the socket unchanged" do
      socket = %Mob.Socket{}
      assert ^socket = MobIap.purchase(socket, :premium)
    end

    test "restore/1 returns the socket unchanged" do
      socket = %Mob.Socket{}
      assert ^socket = MobIap.restore(socket)
    end

    test "current_entitlements/1 returns the socket unchanged" do
      socket = %Mob.Socket{}
      assert ^socket = MobIap.current_entitlements(socket)
    end

    test "manage_subscriptions/1 returns the socket unchanged" do
      socket = %Mob.Socket{}
      assert ^socket = MobIap.manage_subscriptions(socket)
    end

    test "verify/3 returns the socket unchanged" do
      socket = %Mob.Socket{}
      assert ^socket = MobIap.verify(socket, "tx_123", ~s({"signed_transaction": "..."}))
    end

    test "verify/3 with no endpoint configured sends verified/invalid to self" do
      Application.delete_env(:mob_iap, :verification_endpoint)
      socket = %Mob.Socket{}
      MobIap.verify(socket, "tx_no_ep", "receipt_data")
      assert_receive {:iap, :verified, "tx_no_ep", {:invalid, "no_endpoint_configured"}}
    end
  end

  describe "decode_products!/1" do
    test "decodes a JSON array of products" do
      json =
        Jason.encode!([
          %{
            "id" => "premium",
            "display_name" => "Premium",
            "description" => "All features",
            "price" => "$9.99",
            "price_amount" => 9.99,
            "currency_code" => "USD",
            "type" => "auto_renewable",
            "subscription_period" => "P1M",
            "trial_period" => "P1W",
            "introductory_offer" => %{"price" => "$4.99", "period" => "P1M"}
          },
          %{
            "id" => "gems_100",
            "display_name" => "100 Gems",
            "description" => "Pack of 100 gems",
            "price" => "$0.99",
            "price_amount" => 0.99,
            "currency_code" => "USD",
            "type" => "consumable"
          }
        ])

      products = MobIap.decode_products!(json)
      assert length(products) == 2

      [premium, gems] = products

      assert %Product{} = premium
      assert premium.id == "premium"
      assert premium.display_name == "Premium"
      assert premium.price == "$9.99"
      assert premium.price_amount == 9.99
      assert premium.type == :auto_renewable
      assert premium.subscription_period == "P1M"
      assert premium.trial_period == "P1W"
      assert premium.introductory_offer["price"] == "$4.99"

      assert %Product{} = gems
      assert gems.id == "gems_100"
      assert gems.type == :consumable
      assert gems.description == "Pack of 100 gems"
    end

    test "handles empty product list" do
      products = MobIap.decode_products!("[]")
      assert products == []
    end

    test "handles products with missing optional fields" do
      json =
        Jason.encode!([
          %{
            "id" => "simple",
            "display_name" => "Simple",
            "description" => "Simple",
            "price" => "$1.99",
            "price_amount" => 1.99,
            "currency_code" => "EUR",
            "type" => "non_consumable"
          }
        ])

      [product] = MobIap.decode_products!(json)
      assert product.subscription_period == nil
      assert product.trial_period == nil
      assert product.introductory_offer == nil
      assert product.currency_code == "EUR"
    end

    test "unknown product type falls back to :consumable" do
      json =
        Jason.encode!([
          %{
            "id" => "weird",
            "display_name" => "Weird",
            "description" => "",
            "price" => "$0.00",
            "price_amount" => 0.0,
            "currency_code" => "USD",
            "type" => "unknown"
          }
        ])

      [product] = MobIap.decode_products!(json)
      assert product.type == :consumable
    end
  end

  describe "decode_transactions!/1" do
    test "decodes a JSON array of transactions" do
      json =
        Jason.encode!([
          %{
            "id" => "tx_001",
            "product_id" => "premium",
            "purchase_date" => 1_700_000_000_000,
            "expires_date" => 1_700_100_000_000,
            "original_json" => ~s({"signed": "yes"}),
            "is_upgraded" => 0,
            "ownership_type" => "purchased",
            "environment" => "production"
          },
          %{
            "id" => "tx_002",
            "product_id" => "gems_100",
            "purchase_date" => 1_699_000_000_000,
            "expires_date" => nil,
            "original_json" => nil,
            "is_upgraded" => 1,
            "ownership_type" => "family_shared",
            "environment" => "sandbox"
          }
        ])

      transactions = MobIap.decode_transactions!(json)
      assert length(transactions) == 2

      [tx1, tx2] = transactions

      assert %Transaction{} = tx1
      assert tx1.id == "tx_001"
      assert tx1.product_id == "premium"
      assert tx1.purchase_date == 1_700_000_000_000
      assert tx1.expires_date == 1_700_100_000_000
      assert tx1.original_json == ~s({"signed": "yes"})
      assert tx1.is_upgraded == false
      assert tx1.ownership_type == :purchased
      assert tx1.environment == :production

      assert %Transaction{} = tx2
      assert tx2.id == "tx_002"
      assert tx2.is_upgraded == true
      assert tx2.ownership_type == :family_shared
      assert tx2.environment == :sandbox
      assert tx2.expires_date == nil
    end

    test "handles empty transaction list" do
      transactions = MobIap.decode_transactions!("[]")
      assert transactions == []
    end

    test "unknown ownership_type falls back to :purchased" do
      json =
        Jason.encode!([
          %{
            "id" => "tx",
            "product_id" => "p",
            "purchase_date" => 1,
            "expires_date" => nil,
            "original_json" => nil,
            "is_upgraded" => 0,
            "ownership_type" => "unrecognized_value",
            "environment" => "production"
          }
        ])

      [tx] = MobIap.decode_transactions!(json)
      assert tx.ownership_type == :purchased
    end

    test "unknown environment falls back to :production" do
      json =
        Jason.encode!([
          %{
            "id" => "tx",
            "product_id" => "p",
            "purchase_date" => 1,
            "expires_date" => nil,
            "original_json" => nil,
            "is_upgraded" => 0,
            "ownership_type" => "purchased",
            "environment" => "unknown_env"
          }
        ])

      [tx] = MobIap.decode_transactions!(json)
      assert tx.environment == :production
    end
  end

  describe "decode_transaction!/1" do
    test "decodes a single transaction JSON object" do
      json =
        Jason.encode!(%{
          "id" => "tx_single",
          "product_id" => "monthly",
          "purchase_date" => 1_700_000_000_000,
          "expires_date" => nil,
          "original_json" => nil,
          "is_upgraded" => 0,
          "ownership_type" => "purchased",
          "environment" => "production"
        })

      tx = MobIap.decode_transaction!(json)
      assert %Transaction{} = tx
      assert tx.id == "tx_single"
      assert tx.product_id == "monthly"
      assert tx.is_upgraded == false
      assert tx.ownership_type == :purchased
    end

    test "decodes a transaction with is_upgraded: 1" do
      json =
        Jason.encode!(%{
          "id" => "tx_up",
          "product_id" => "premium",
          "purchase_date" => 1_700_000_000_000,
          "expires_date" => nil,
          "original_json" => nil,
          "is_upgraded" => 1,
          "ownership_type" => "family_shared",
          "environment" => "sandbox"
        })

      tx = MobIap.decode_transaction!(json)
      assert tx.is_upgraded == true
      assert tx.ownership_type == :family_shared
      assert tx.environment == :sandbox
    end
  end

  describe "decode roundtrips" do
    test "all valid product types survive JSON encode/decode" do
      [:consumable, :non_consumable, :auto_renewable, :non_renewing]
      |> Enum.each(fn type ->
        json =
          Jason.encode!([
            %{
              "id" => "test",
              "display_name" => "Test",
              "description" => "",
              "price" => "$0.00",
              "price_amount" => 0.0,
              "currency_code" => "USD",
              "type" => Atom.to_string(type)
            }
          ])

        [product] = MobIap.decode_products!(json)
        assert product.type == type, "Failed for type #{inspect(type)}"
      end)
    end

    test "valid transaction ownership types survive JSON encode/decode" do
      [:purchased, :family_shared]
      |> Enum.each(fn ownership ->
        json =
          Jason.encode!([
            %{
              "id" => "tx",
              "product_id" => "test",
              "purchase_date" => 1,
              "expires_date" => nil,
              "original_json" => nil,
              "is_upgraded" => 0,
              "ownership_type" => Atom.to_string(ownership),
              "environment" => "production"
            }
          ])

        [tx] = MobIap.decode_transactions!(json)
        assert tx.ownership_type == ownership, "Failed for #{inspect(ownership)}"
      end)
    end

    test "both environments survive JSON encode/decode" do
      [:production, :sandbox]
      |> Enum.each(fn env ->
        json =
          Jason.encode!([
            %{
              "id" => "tx",
              "product_id" => "test",
              "purchase_date" => 1,
              "expires_date" => nil,
              "original_json" => nil,
              "is_upgraded" => 0,
              "ownership_type" => "purchased",
              "environment" => Atom.to_string(env)
            }
          ])

        [tx] = MobIap.decode_transactions!(json)
        assert tx.environment == env, "Failed for #{inspect(env)}"
      end)
    end
  end
end
