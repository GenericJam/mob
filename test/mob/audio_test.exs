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
end
