defmodule Mob.SpeechTest do
  use ExUnit.Case, async: true

  alias Mob.Speech

  describe "transcribe_audio_opts/1" do
    test "defaults to platform locale and server-capable recognition" do
      assert Speech.transcribe_audio_opts([]) == %{
               "locale" => "",
               "requires_on_device_recognition" => false
             }
    end

    test "custom locale and on-device setting are passed through" do
      assert Speech.transcribe_audio_opts(locale: "en-US", requires_on_device_recognition: true) ==
               %{
                 "locale" => "en-US",
                 "requires_on_device_recognition" => true
               }
    end
  end
end
