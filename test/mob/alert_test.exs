defmodule Mob.AlertTest do
  use ExUnit.Case, async: true

  # Tests cover the pure encoding layer. NIF-calling functions (alert/2,
  # action_sheet/2, toast/3) require a device and are tested on-device.

  # ── encode_buttons/1 ──────────────────────────────────────────────────────

  describe "encode_buttons/1" do
    test "encodes label, style, action as strings" do
      json = Mob.Alert.encode_buttons([[label: "OK", style: :cancel, action: :dismiss]])
      decoded = :json.decode(json)
      assert [%{"label" => "OK", "style" => "cancel", "action" => "dismiss"}] = decoded
    end

    test "defaults style to default when omitted" do
      json = Mob.Alert.encode_buttons([[label: "OK"]])
      [btn] = :json.decode(json)
      assert btn["style"] == "default"
    end

    test "defaults action to dismiss when omitted" do
      json = Mob.Alert.encode_buttons([[label: "OK"]])
      [btn] = :json.decode(json)
      assert btn["action"] == "dismiss"
    end

    test "encodes destructive style" do
      json = Mob.Alert.encode_buttons([[label: "Delete", style: :destructive, action: :delete]])
      [btn] = :json.decode(json)
      assert btn["style"] == "destructive"
      assert btn["action"] == "delete"
    end

    test "encodes multiple buttons" do
      buttons = [
        [label: "Delete", style: :destructive, action: :delete],
        [label: "Cancel", style: :cancel]
      ]
      json = Mob.Alert.encode_buttons(buttons)
      decoded = :json.decode(json)
      assert length(decoded) == 2
      assert Enum.at(decoded, 0)["label"] == "Delete"
      assert Enum.at(decoded, 1)["label"] == "Cancel"
    end

    test "encodes empty list" do
      json = Mob.Alert.encode_buttons([])
      assert :json.decode(json) == []
    end

    test "converts atom label to string" do
      json = Mob.Alert.encode_buttons([[label: :confirm]])
      [btn] = :json.decode(json)
      assert btn["label"] == "confirm"
    end

    test "output is valid JSON binary" do
      result = Mob.Alert.encode_buttons([[label: "Test"]])
      assert is_binary(result)
      assert String.starts_with?(result, "[")
    end
  end
end
