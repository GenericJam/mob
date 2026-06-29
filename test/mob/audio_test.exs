defmodule Mob.AudioTest do
  use ExUnit.Case, async: true

  alias Mob.Audio

  describe "play_opts/1" do
    test "defaults: loop false, volume 1.0" do
      assert Audio.play_opts([]) == %{"loop" => false, "volume" => 1.0}
    end

    test "loop: true is passed through" do
      assert Audio.play_opts(loop: true) == %{"loop" => true, "volume" => 1.0}
    end

    test "volume is passed through as float" do
      assert Audio.play_opts(volume: 0.5) == %{"loop" => false, "volume" => 0.5}
    end

    test "integer volume is coerced to float" do
      opts = Audio.play_opts(volume: 1)
      assert opts["volume"] === 1.0
    end

    test "both options can be set together" do
      assert Audio.play_opts(loop: true, volume: 0.8) == %{"loop" => true, "volume" => 0.8}
    end

    test "keys are strings, not atoms" do
      opts = Audio.play_opts([])
      assert Map.has_key?(opts, "loop")
      assert Map.has_key?(opts, "volume")
      refute Map.has_key?(opts, :loop)
      refute Map.has_key?(opts, :volume)
    end
  end

  describe "recording_opts/1" do
    test "defaults: format aac, quality medium" do
      assert Audio.recording_opts([]) == %{"format" => "aac", "quality" => "medium"}
    end

    test "format :wav becomes the string \"wav\"" do
      assert Audio.recording_opts(format: :wav) == %{"format" => "wav", "quality" => "medium"}
    end

    test "quality :high becomes the string \"high\"" do
      assert Audio.recording_opts(quality: :high) == %{"format" => "aac", "quality" => "high"}
    end

    test "quality :low becomes the string \"low\"" do
      assert Audio.recording_opts(quality: :low) == %{"format" => "aac", "quality" => "low"}
    end

    test "keys are strings, not atoms" do
      opts = Audio.recording_opts([])
      assert Map.has_key?(opts, "format")
      assert Map.has_key?(opts, "quality")
      refute Map.has_key?(opts, :format)
      refute Map.has_key?(opts, :quality)
    end
  end

  describe "set_volume/2 guard" do
    test "rejects a string volume" do
      socket = Mob.Socket.new(MyScreen)
      assert_raise FunctionClauseError, fn -> Audio.set_volume(socket, "loud") end
    end

    test "rejects nil" do
      socket = Mob.Socket.new(MyScreen)
      assert_raise FunctionClauseError, fn -> Audio.set_volume(socket, nil) end
    end
  end

  describe "play_at_opts/1" do
    test "default volume is 1.0" do
      assert Audio.play_at_opts([]) == %{"volume" => 1.0}
    end

    test "volume is passed through as float" do
      assert Audio.play_at_opts(volume: 0.5) == %{"volume" => 0.5}
    end

    test "integer volume is coerced to float" do
      opts = Audio.play_at_opts(volume: 1)
      assert opts["volume"] === 1.0
    end

    test "does NOT include a loop key — play_at is single-shot" do
      # Scheduled playback is one-shot by design. Looping a sample-aligned
      # buffer requires re-scheduling each iteration on the audio hardware
      # clock, which is not what we want for orchestra cues.
      refute Map.has_key?(Audio.play_at_opts([]), "loop")
    end

    test "keys are strings, not atoms" do
      opts = Audio.play_at_opts([])
      assert Map.has_key?(opts, "volume")
      refute Map.has_key?(opts, :volume)
    end
  end

  describe "play_at/4 guard" do
    test "rejects a non-integer at_wall_ms" do
      socket = Mob.Socket.new(MyScreen)

      assert_raise FunctionClauseError, fn ->
        Audio.play_at(socket, "/tmp/x.wav", 1.5)
      end
    end

    test "rejects a string at_wall_ms" do
      socket = Mob.Socket.new(MyScreen)

      assert_raise FunctionClauseError, fn ->
        Audio.play_at(socket, "/tmp/x.wav", "now")
      end
    end

    test "rejects nil at_wall_ms" do
      socket = Mob.Socket.new(MyScreen)

      assert_raise FunctionClauseError, fn ->
        Audio.play_at(socket, "/tmp/x.wav", nil)
      end
    end
  end

  describe "decode_status/1" do
    test "maps the native 4-tuple to a status map" do
      assert Audio.decode_status({0.8, 0.0, 1.0, 0.0}) ==
               %{volume: 0.8, muted: false, route: :speaker, other_audio: false}
    end

    test "muted and other_audio are booleans from the 0/1 flags" do
      status = Audio.decode_status({0.0, 1.0, 0.0, 1.0})
      assert status.muted == true
      assert status.other_audio == true
      assert status.route == :none
    end

    test "route codes decode to atoms (float codes from the NIF too)" do
      assert Audio.decode_status({0.5, 0.0, 2.0, 0.0}).route == :headphones
      assert Audio.decode_status({0.5, 0.0, 3.0, 0.0}).route == :bluetooth
      assert Audio.decode_status({0.5, 0.0, 4.0, 0.0}).route == :receiver
    end

    test "an unknown route code is :unknown, not a crash" do
      assert Audio.decode_status({0.5, 0.0, 99.0, 0.0}).route == :unknown
    end

    test "a non-tuple (e.g. NIF not loaded) yields a safe default" do
      assert Audio.decode_status(:error) ==
               %{volume: 0.0, muted: false, route: :unknown, other_audio: false}
    end
  end

  describe "decode_level/1" do
    test "passes through {rms, peak} when there is signal" do
      assert Audio.decode_level({-18.0, -6.0}) == {-18.0, -6.0}
    end

    test "a peak at or below -120 dB reads as :silent" do
      assert Audio.decode_level({-160.0, -160.0}) == :silent
      assert Audio.decode_level({-130.0, -120.0}) == :silent
    end

    test "an atom result becomes {:error, atom}" do
      assert Audio.decode_level(:needs_record_audio) == {:error, :needs_record_audio}
      assert Audio.decode_level(:unsupported_on_platform) == {:error, :unsupported_on_platform}
      assert Audio.decode_level(:not_playing) == {:error, :not_playing}
    end

    test "an unexpected shape becomes {:error, :unknown}" do
      assert Audio.decode_level(42) == {:error, :unknown}
    end
  end
end
