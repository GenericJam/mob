defmodule MobIap.Transaction do
  @moduledoc """
  A completed or in-progress purchase transaction.

  Returned by `MobIap.purchase/2`, `MobIap.restore/1`, and
  `MobIap.current_entitlements/1`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          product_id: String.t(),
          purchase_date: integer(),
          expires_date: integer() | nil,
          original_json: String.t() | nil,
          is_upgraded: boolean(),
          ownership_type: ownership_type(),
          environment: environment()
        }

  @type ownership_type :: :purchased | :family_shared

  @type environment :: :production | :sandbox

  defstruct [
    :id,
    :product_id,
    :purchase_date,
    expires_date: nil,
    original_json: nil,
    is_upgraded: false,
    ownership_type: :purchased,
    environment: :production
  ]

  @doc """
  Create a Transaction struct from a keyword list.

  Used primarily in tests and for constructing mock data. The native
  bridges produce JSON that is decoded via `MobIap.decode_transaction!/1`.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    struct!(__MODULE__, fields)
  end
end
