defmodule Mob.AppTest do
  use ExUnit.Case, async: false

  describe "configure_ios_inet_db/0" do
    test "is a no-op on host BEAM where the NIF isn't loaded" do
      lookup_before = :inet_db.res_option(:lookup)

      assert :ok = Mob.App.configure_ios_inet_db()

      assert :inet_db.res_option(:lookup) == lookup_before
    end

    test "idempotent — repeated calls don't crash or stack state" do
      assert :ok = Mob.App.configure_ios_inet_db()
      assert :ok = Mob.App.configure_ios_inet_db()
      assert :ok = Mob.App.configure_ios_inet_db()
    end
  end
end
