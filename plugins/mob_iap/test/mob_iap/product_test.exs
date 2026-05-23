defmodule MobIap.ProductTest do
  use ExUnit.Case, async: true

  alias MobIap.Product

  describe "new/1" do
    test "creates a product struct from a keyword list" do
      product =
        Product.new(
          id: :premium,
          display_name: "Premium Subscription",
          description: "Unlock all features",
          price: "$9.99",
          type: :auto_renewable
        )

      assert %Product{} = product
      assert product.id == :premium
      assert product.display_name == "Premium Subscription"
      assert product.description == "Unlock all features"
      assert product.price == "$9.99"
      assert product.type == :auto_renewable
    end

    test "defaults optional fields" do
      product = Product.new(id: :consumable, display_name: "Gems", price: "$0.99")

      assert product.description == ""
      assert product.type == :consumable
      assert product.price_amount == 0.0
      assert product.currency_code == "USD"
      assert product.subscription_period == nil
      assert product.trial_period == nil
      assert product.introductory_offer == nil
    end

    test "accepts subscription fields" do
      product =
        Product.new(
          id: :monthly,
          display_name: "Monthly",
          price: "$4.99",
          type: :auto_renewable,
          subscription_period: "P1M",
          trial_period: "P1W",
          introductory_offer: %{"price" => "$2.99", "period" => "P1M"}
        )

      assert product.subscription_period == "P1M"
      assert product.trial_period == "P1W"
      assert intro = product.introductory_offer
      assert intro["price"] == "$2.99"
    end
  end

  describe "type validation" do
    test "accepts all valid product types" do
      [:consumable, :non_consumable, :auto_renewable, :non_renewing]
      |> Enum.each(fn type ->
        product = Product.new(id: type, display_name: "Test", price: "$0.99", type: type)
        assert product.type == type
      end)
    end
  end
end
