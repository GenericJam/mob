defmodule MobIap.Product do
  @moduledoc """
  A product available for purchase from the app store.

  Returned by `MobIap.fetch_products/2`. Fields are populated from
  StoreKit 2 / Play Billing responses translated through the native bridge.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          description: String.t(),
          price: String.t(),
          price_amount: float(),
          currency_code: String.t(),
          type: product_type(),
          subscription_period: String.t() | nil,
          introductory_offer: map() | nil,
          trial_period: String.t() | nil
        }

  @type product_type ::
          :consumable
          | :non_consumable
          | :auto_renewable
          | :non_renewing

  defstruct [
    :id,
    :display_name,
    :price,
    description: "",
    price_amount: 0.0,
    currency_code: "USD",
    type: :consumable,
    subscription_period: nil,
    introductory_offer: nil,
    trial_period: nil
  ]

  @doc """
  Create a Product struct from a keyword list.

  Used primarily in tests and for constructing mock data. The native
  bridges produce JSON that is decoded via `MobIap.decode_products!/1`.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    struct!(__MODULE__, fields)
  end
end
