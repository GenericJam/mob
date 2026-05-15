defmodule Mob.Bt.HfpTest do
  use ExUnit.Case, async: true

  alias Mob.Bt.Hfp

  describe "encode_vendor_at_opts/1" do
    test "default — empty company_ids list" do
      assert :json.decode(Hfp.encode_vendor_at_opts([])) == %{"company_ids" => []}
    end

    test "passes through a single company id" do
      assert :json.decode(Hfp.encode_vendor_at_opts(company_ids: [313])) == %{
               "company_ids" => [313]
             }
    end

    test "passes through several company ids in order" do
      assert :json.decode(Hfp.encode_vendor_at_opts(company_ids: [313, 76, 10])) == %{
               "company_ids" => [313, 76, 10]
             }
    end

    test "ignores unknown opts (forward-compatible)" do
      assert :json.decode(Hfp.encode_vendor_at_opts(company_ids: [313], extra: :ignored)) == %{
               "company_ids" => [313]
             }
    end
  end
end
