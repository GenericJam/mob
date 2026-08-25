defmodule Mob.FontTest do
  use ExUnit.Case, async: true

  alias Mob.Font

  describe "android_resource_name/1" do
    test "lowercases and drops the extension" do
      assert Font.android_resource_name("Georgia.ttf") == "georgia"
    end

    test "replaces non-alphanumeric characters with underscores" do
      assert Font.android_resource_name("Inter-Regular.otf") == "inter_regular"
      assert Font.android_resource_name("My Font 2.ttf") == "my_font_2"
    end

    test "prefixes a leading non-letter so the result is a valid resource identifier" do
      assert Font.android_resource_name("123Sans.ttf") == "f_123sans"
    end
  end
end
