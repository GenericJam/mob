# This source-contract test guards UIKit behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeAlertActionTest do
  use ExUnit.Case, async: true

  alias Mob.Test.NativeSource

  @source Path.expand("../../ios/mob_nif.m", __DIR__) |> File.read!()

  @alert NativeSource.region(
           @source,
           "static ERL_NIF_TERM nif_alert_show",
           "nif_action_sheet_show"
         )
         |> NativeSource.code_only(:objc)

  @action_sheet NativeSource.region(
                  @source,
                  "static ERL_NIF_TERM nif_action_sheet_show",
                  "// ── NIF: toast_show/2"
                )
                |> NativeSource.code_only(:objc)

  test "iOS alert handlers convert retained action strings at delivery time" do
    refute @alert =~ "const char *act_c = [action UTF8String]"
    refute @action_sheet =~ "const char *act_c = [action UTF8String]"

    assert @alert =~ "mob_deliver_alert_action([action UTF8String]);"
    assert @action_sheet =~ "mob_deliver_alert_action([action UTF8String]);"
  end
end
