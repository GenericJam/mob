defmodule Mob.CameraTest do
  use ExUnit.Case, async: true

  alias Mob.Camera

  describe "frame_stream_opts/1" do
    test "defaults: 640×640 rgb_f32 back camera, no throttle" do
      assert Camera.frame_stream_opts([]) == %{
               "width" => 640,
               "height" => 640,
               "format" => "rgb_f32",
               "facing" => "back",
               "throttle_ms" => 0
             }
    end

    test "width / height override" do
      opts = Camera.frame_stream_opts(width: 320, height: 240)
      assert opts["width"] == 320
      assert opts["height"] == 240
    end

    test ":bgra_u8 format is passed through as the string \"bgra_u8\"" do
      opts = Camera.frame_stream_opts(format: :bgra_u8)
      assert opts["format"] == "bgra_u8"
    end

    test ":front facing is passed through as the string \"front\"" do
      opts = Camera.frame_stream_opts(facing: :front)
      assert opts["facing"] == "front"
    end

    test "throttle_ms is passed through as an integer" do
      opts = Camera.frame_stream_opts(throttle_ms: 100)
      assert opts["throttle_ms"] == 100
    end

    test "keys are strings, matching the rest of the NIF JSON surface" do
      opts = Camera.frame_stream_opts([])
      # Audio + start_preview use string keys for their JSON-encoded
      # NIF args; frame_stream_opts should follow the same convention so
      # the iOS-side NSJSONSerialization deserialises a consistent shape.
      for key <- ["width", "height", "format", "facing", "throttle_ms"] do
        assert Map.has_key?(opts, key), "expected key #{inspect(key)}"
      end

      for atom <- [:width, :height, :format, :facing, :throttle_ms] do
        refute Map.has_key?(opts, atom), "found atom key #{inspect(atom)}"
      end
    end

    test "every option is independently overridable" do
      opts =
        Camera.frame_stream_opts(
          width: 1280,
          height: 720,
          format: :bgra_u8,
          facing: :front,
          throttle_ms: 33
        )

      assert opts == %{
               "width" => 1280,
               "height" => 720,
               "format" => "bgra_u8",
               "facing" => "front",
               "throttle_ms" => 33
             }
    end

    test "serialises to JSON cleanly (this is what hits the NIF)" do
      # The NIF receives the JSON-encoded result, so make sure the map
      # round-trips through :json without losing data. Any future
      # option that's not JSON-serialisable would fail here.
      opts = Camera.frame_stream_opts([])
      json = :json.encode(opts) |> IO.iodata_to_binary()

      decoded = :json.decode(json)
      assert decoded == opts
    end
  end
end
