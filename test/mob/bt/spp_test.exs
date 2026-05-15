defmodule Mob.Bt.SppTest do
  use ExUnit.Case, async: true

  alias Mob.Bt.Spp

  @device %{address: "AA:BB:CC:DD:EE:FF", name: "Sensor"}
  @standard_spp_uuid "00001101-0000-1000-8000-00805F9B34FB"

  describe "encode_connect/2" do
    test "defaults to the standard SPP UUID + secure RFCOMM" do
      decoded = :json.decode(Spp.encode_connect(@device, []))
      assert decoded["uuid"] == @standard_spp_uuid
      assert decoded["secure"] == true
      assert decoded["address"] == "AA:BB:CC:DD:EE:FF"
    end

    test "honors a custom :uuid" do
      custom = "12345678-1234-1234-1234-123456789012"
      decoded = :json.decode(Spp.encode_connect(@device, uuid: custom))
      assert decoded["uuid"] == custom
    end

    test "honors secure: false (insecure RFCOMM for legacy devices)" do
      decoded = :json.decode(Spp.encode_connect(@device, secure: false))
      assert decoded["secure"] == false
    end

    test "drops nil-valued device fields but keeps explicit secure: false" do
      device = %{address: "AA:BB", name: "X", uuids: nil, bond_state: nil}
      decoded = :json.decode(Spp.encode_connect(device, secure: false))
      refute Map.has_key?(decoded, "uuids")
      refute Map.has_key?(decoded, "bond_state")
      assert decoded["secure"] == false
    end
  end
end
