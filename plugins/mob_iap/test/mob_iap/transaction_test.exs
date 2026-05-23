defmodule MobIap.TransactionTest do
  use ExUnit.Case, async: true

  alias MobIap.Transaction

  describe "new/1" do
    test "creates a transaction struct from a keyword list" do
      tx =
        Transaction.new(
          id: "tx_001",
          product_id: :premium,
          purchase_date: 1_700_000_000_000
        )

      assert %Transaction{} = tx
      assert tx.id == "tx_001"
      assert tx.product_id == :premium
      assert tx.purchase_date == 1_700_000_000_000
    end

    test "defaults optional fields" do
      tx =
        Transaction.new(
          id: "tx_002",
          product_id: :gems,
          purchase_date: 1_700_000_000_000
        )

      assert tx.expires_date == nil
      assert tx.original_json == nil
      assert tx.is_upgraded == false
      assert tx.ownership_type == :purchased
      assert tx.environment == :production
    end

    test "accepts all fields" do
      tx =
        Transaction.new(
          id: "tx_003",
          product_id: :monthly,
          purchase_date: 1_700_000_000_000,
          expires_date: 1_700_100_000_000,
          original_json: ~s({"foo": "bar"}),
          is_upgraded: true,
          ownership_type: :family_shared,
          environment: :sandbox
        )

      assert tx.expires_date == 1_700_100_000_000
      assert tx.original_json == ~s({"foo": "bar"})
      assert tx.is_upgraded
      assert tx.ownership_type == :family_shared
      assert tx.environment == :sandbox
    end
  end

  describe "ownership types" do
    test "accepts all valid ownership types" do
      [:purchased, :family_shared]
      |> Enum.each(fn ownership ->
        tx =
          Transaction.new(
            id: "tx",
            product_id: :test,
            purchase_date: 1,
            ownership_type: ownership
          )

        assert tx.ownership_type == ownership
      end)
    end
  end

  describe "environment" do
    test "accepts production and sandbox" do
      prod = Transaction.new(id: "a", product_id: :x, purchase_date: 1, environment: :production)
      sand = Transaction.new(id: "b", product_id: :y, purchase_date: 1, environment: :sandbox)

      assert prod.environment == :production
      assert sand.environment == :sandbox
    end
  end
end
