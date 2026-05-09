defmodule Mob.VendorUsbTest do
  use ExUnit.Case, async: true

  alias Mob.VendorUsb

  describe "normalize_message/1 — devices_json" do
    test "decodes a list of device records" do
      json =
        IO.iodata_to_binary(:json.encode([
          %{
            "vendor_id" => 0x1234,
            "product_id" => 0x5678,
            "manufacturer" => "Acme Inc.",
            "product" => "Widget 9000",
            "serial" => "SN-000001",
            "ref" => "/dev/bus/usb/001/002"
          }
        ]))

      assert {:peripheral, :vendor_usb, :devices, nil, [device]} =
               VendorUsb.normalize_message(
                 {:peripheral, :vendor_usb, :devices_json, nil, json}
               )

      assert device.vendor_id == 0x1234
      assert device.product_id == 0x5678
      assert device.manufacturer == "Acme Inc."
      assert device.product == "Widget 9000"
      assert device.serial == "SN-000001"
      assert device.ref == "/dev/bus/usb/001/002"
    end

    test "empty list passes through cleanly" do
      assert {:peripheral, :vendor_usb, :devices, nil, []} =
               VendorUsb.normalize_message(
                 {:peripheral, :vendor_usb, :devices_json, nil, IO.iodata_to_binary(:json.encode([]))}
               )
    end

    test "tolerates missing optional string fields" do
      json =
        IO.iodata_to_binary(:json.encode([
          %{
            "vendor_id" => 0x1234,
            "product_id" => 0x5678,
            "ref" => "/dev/bus/usb/001/002"
          }
        ]))

      assert {:peripheral, :vendor_usb, :devices, nil, [device]} =
               VendorUsb.normalize_message(
                 {:peripheral, :vendor_usb, :devices_json, nil, json}
               )

      assert device.manufacturer == nil
      assert device.product == nil
      assert device.serial == nil
    end
  end

  describe "normalize_message/1 — permission events" do
    test "permission_granted_json becomes :permission_granted with a device map" do
      json =
        IO.iodata_to_binary(:json.encode(%{
          "vendor_id" => 0x1234,
          "product_id" => 0x5678,
          "ref" => "/dev/bus/usb/001/002"
        }))

      assert {:peripheral, :vendor_usb, :permission_granted, nil, device} =
               VendorUsb.normalize_message(
                 {:peripheral, :vendor_usb, :permission_granted_json, nil, json}
               )

      assert device.ref == "/dev/bus/usb/001/002"
    end

    test "permission_denied_json becomes :permission_denied" do
      json = IO.iodata_to_binary(:json.encode(%{"ref" => "/dev/bus/usb/001/002"}))

      assert {:peripheral, :vendor_usb, :permission_denied, nil, device} =
               VendorUsb.normalize_message(
                 {:peripheral, :vendor_usb, :permission_denied_json, nil, json}
               )

      assert device.ref == "/dev/bus/usb/001/002"
    end
  end

  describe "normalize_message/1 — opened_json" do
    test "decodes opened with session id and device payload" do
      json =
        IO.iodata_to_binary(:json.encode(%{
          "vendor_id" => 0x1234,
          "product_id" => 0x5678,
          "ref" => "/dev/bus/usb/001/002"
        }))

      assert {:peripheral, :vendor_usb, :opened, 7, device} =
               VendorUsb.normalize_message(
                 {:peripheral, :vendor_usb, :opened_json, 7, json}
               )

      assert device.vendor_id == 0x1234
    end
  end

  describe "normalize_message/1 — passthrough" do
    test "non-JSON peripheral events pass through unchanged" do
      msg = {:peripheral, :vendor_usb, :data, 7, <<1, 2, 3>>}
      assert VendorUsb.normalize_message(msg) == msg
    end

    test "write_complete passes through unchanged" do
      msg = {:peripheral, :vendor_usb, :write_complete, 7, %{bytes: 4}}
      assert VendorUsb.normalize_message(msg) == msg
    end

    test "error event passes through unchanged" do
      msg = {:peripheral, :vendor_usb, :error, 7, :write_timeout}
      assert VendorUsb.normalize_message(msg) == msg
    end

    test "unrelated messages pass through unchanged" do
      msg = {:something, :else}
      assert VendorUsb.normalize_message(msg) == msg
    end
  end
end
