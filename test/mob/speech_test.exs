defmodule Mob.SpeechTest do
  use ExUnit.Case, async: true

  # The speak/3 and stop_speaking/1 paths call into mob_nif, which isn't loaded
  # on the host (same as Mob.Haptic / Mob.Clipboard — untested for that reason).
  # The testable logic is the option whitelisting/encoding feeding the NIF and
  # the decoding of what tts_voices/0 returns.

  test "speak_opts whitelists known keys and stringifies them" do
    assert Mob.Speech.speak_opts(rate: 0.5, pitch: 1.2, voice: "en-US") ==
             %{"rate" => 0.5, "pitch" => 1.2, "voice" => "en-US"}
  end

  test "speak_opts passes a voice id through untouched" do
    id = "com.apple.voice.compact.en-US.Samantha"
    assert Mob.Speech.speak_opts(voice: id) == %{"voice" => id}
  end

  test "speak_opts drops unknown options so typos can't reach the native layer" do
    assert Mob.Speech.speak_opts(rate: 0.5, bogus: 1, foo: :bar) == %{"rate" => 0.5}
  end

  test "speak_opts on an empty list JSON-encodes to an empty object" do
    assert Mob.Speech.speak_opts([]) == %{}
    assert IO.iodata_to_binary(:json.encode(Mob.Speech.speak_opts([]))) == "{}"
  end

  test "speak/3 requires binary text" do
    assert_raise FunctionClauseError, fn -> Mob.Speech.speak(%{}, :not_a_binary) end
  end

  describe "decode_voices/1" do
    test "maps Android's Voice.QUALITY_* numbers onto the five-step scale" do
      json =
        voices_json([
          voice("a", "en-US", 100),
          voice("b", "en-US", 200),
          voice("c", "en-US", 300),
          voice("d", "en-US", 400),
          voice("e", "en-US", 500)
        ])

      assert json |> Mob.Speech.decode_voices() |> Map.new(&{&1.id, &1.quality}) ==
               %{"a" => :very_low, "b" => :low, "c" => :normal, "d" => :high, "e" => :very_high}
    end

    test "maps iOS's default/enhanced/premium onto normal/high/very_high" do
      json = voices_json([voice("d", "en-US", 1), voice("e", "en-US", 2), voice("p", "en-US", 3)])

      assert json |> Mob.Speech.decode_voices() |> Map.new(&{&1.id, &1.quality}) ==
               %{"d" => :normal, "e" => :high, "p" => :very_high}
    end

    test "sorts by language, then best quality first, then name" do
      json =
        voices_json([
          voice("fr-low", "fr-FR", 200, "Amelie"),
          voice("en-normal-z", "en-US", 300, "Zed"),
          voice("en-high", "en-US", 400, "Yan"),
          voice("en-normal-a", "en-US", 300, "Abe"),
          voice("de", "de-DE", 300, "Anna")
        ])

      assert json |> Mob.Speech.decode_voices() |> Enum.map(& &1.id) ==
               ["de", "en-high", "en-normal-a", "en-normal-z", "fr-low"]
    end

    test "builds the documented shape; same name puts the on-device voice first" do
      json =
        voices_json([
          voice("en-us-x-sfg-network", "en-US", 400, "English (United States) sfg", true),
          voice("en-us-x-sfg-local", "en-US", 400, "English (United States) sfg", false)
        ])

      assert Mob.Speech.decode_voices(json) == [
               %{
                 id: "en-us-x-sfg-local",
                 name: "English (United States) sfg",
                 language: "en-US",
                 quality: :high,
                 network: false
               },
               %{
                 id: "en-us-x-sfg-network",
                 name: "English (United States) sfg",
                 language: "en-US",
                 quality: :high,
                 network: true
               }
             ]
    end
  end

  describe "voices/1" do
    defmodule ListingNif do
      def tts_voices,
        do: ~s([{"id":"v","name":"Vee","language":"en-GB","quality":2,"network":false}])
    end

    defmodule FailedEngineNif do
      def tts_voices, do: :unavailable
    end

    defmodule OldBridgeNif do
      def tts_voices, do: :unsupported
    end

    defmodule OldNativeBuildNif do
      def tts_voices, do: :erlang.nif_error(:not_loaded)
    end

    defmodule NoVoicesNif do
    end

    defmodule BrokenNif do
      def tts_voices, do: raise(ArgumentError, "a bug in the native glue")
    end

    test "decodes what the NIF lists" do
      assert Mob.Speech.voices(ListingNif) ==
               {:ok, [%{id: "v", name: "Vee", language: "en-GB", quality: :high, network: false}]}
    end

    test "an engine that didn't start is :unavailable" do
      assert Mob.Speech.voices(FailedEngineNif) == {:error, :unavailable}
    end

    test "a bridge without ttsVoices is :unsupported" do
      assert Mob.Speech.voices(OldBridgeNif) == {:error, :unsupported}
    end

    test "a native build that predates the NIF is :unsupported, not a crash" do
      assert Mob.Speech.voices(OldNativeBuildNif) == {:error, :unsupported}
    end

    test "a stub module without the function is :unsupported" do
      assert Mob.Speech.voices(NoVoicesNif) == {:error, :unsupported}
    end

    test "the host, where mob_nif isn't loaded, is :unsupported" do
      assert Mob.Speech.voices() == {:error, :unsupported}
    end

    test "an unrelated exception is not swallowed" do
      assert_raise ArgumentError, fn -> Mob.Speech.voices(BrokenNif) end
    end
  end

  defp voice(id, language, quality, name \\ nil, network \\ false),
    do: %{id: id, name: name || id, language: language, quality: quality, network: network}

  defp voices_json(voices), do: voices |> :json.encode() |> IO.iodata_to_binary()
end
