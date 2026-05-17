defmodule Mob.IOS.VisionTest do
  use ExUnit.Case, async: true

  alias Mob.IOS.Vision

  describe "recognize_text_opts/1" do
    test "defaults to accurate OCR with language correction" do
      assert Vision.recognize_text_opts([]) == %{
               "recognition_level" => "accurate",
               "uses_language_correction" => true
             }
    end

    test "recognition level is encoded as a string" do
      assert Vision.recognize_text_opts(recognition_level: :fast) == %{
               "recognition_level" => "fast",
               "uses_language_correction" => true
             }
    end
  end
end
