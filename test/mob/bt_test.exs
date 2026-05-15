defmodule Mob.BtTest do
  use ExUnit.Case, async: true

  alias Mob.Bt

  # The public surface of Mob.Bt + sub-profiles dead-ends in :mob_nif
  # calls, so the unit-testable layer is the JSON the Elixir side
  # hands to the NIF. The encoders are exposed `@doc false` for
  # exactly that reason — tested here, never advertised to users.

  describe "encode_device/1" do
    test "round-trips a minimal device map" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev"}

      assert decoded(Bt.encode_device(device)) == %{
               "address" => "AA:BB:CC:DD:EE:FF",
               "name" => "TestDev"
             }
    end

    test "drops keys whose value is nil" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev", bond_state: nil, uuids: nil}
      decoded = decoded(Bt.encode_device(device))
      assert Map.keys(decoded) |> Enum.sort() == ["address", "name"]
    end

    test "preserves a populated optional field" do
      device = %{
        address: "AA:BB:CC:DD:EE:FF",
        name: "TestDev",
        bond_state: :bonded,
        device_class: 1024,
        uuids: ["00001101-0000-1000-8000-00805F9B34FB"]
      }

      decoded = decoded(Bt.encode_device(device))
      assert decoded["bond_state"] == "bonded"
      assert decoded["device_class"] == 1024
      assert decoded["uuids"] == ["00001101-0000-1000-8000-00805F9B34FB"]
    end

    test "accepts a Keyword list and normalises it to a map" do
      assert decoded(Bt.encode_device(address: "AA:BB", name: "X")) == %{
               "address" => "AA:BB",
               "name" => "X"
             }
    end
  end

  describe "encode_pair/2" do
    test "without a PIN, output matches encode_device/1 byte-for-byte" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev"}
      assert Bt.encode_pair(device, nil) == Bt.encode_device(device)
    end

    test "with a PIN, embeds it in the encoded payload" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev"}
      decoded = decoded(Bt.encode_pair(device, "0000"))
      assert decoded["pin"] == "0000"
      assert decoded["address"] == "AA:BB:CC:DD:EE:FF"
    end
  end

  defp decoded(json) when is_binary(json), do: :json.decode(json)
end
