defmodule Mob.SpeechTest do
  use ExUnit.Case, async: true

  # The speak/3 and stop_speaking/1 paths call into mob_nif, which isn't loaded
  # on the host (same as Mob.Haptic / Mob.Clipboard — untested for that reason).
  # The testable logic is the option whitelisting/encoding feeding the NIF.

  test "speak_opts whitelists known keys and stringifies them" do
    assert Mob.Speech.speak_opts(rate: 0.5, pitch: 1.2, voice: "en-US") ==
             %{"rate" => 0.5, "pitch" => 1.2, "voice" => "en-US"}
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
end
