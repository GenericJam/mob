defmodule Mob.SceneWindowCallsTest do
  @moduledoc """
  `Mob.WebView` and `Mob.Keyboard` act on the window of the calling screen
  (MOB-245): a screen of a further window scene passes its scene id, and the
  primary window's screens (scene `nil`) keep the original NIF arities.

  They call `:mob_nif` directly, so the fake NIF runs in its own VM: defining
  `:mob_nif` here would replace it for every other test.
  """
  use ExUnit.Case, async: false

  test "WebView and keyboard calls go to the calling screen's window" do
    script = ~S'''
    :persistent_term.put(:mob245_test, self())

    Code.compile_string("""
    defmodule :mob_nif do
      defp record(call), do: send(:persistent_term.get(:mob245_test), call)
      def webview_eval_js(code), do: record({:eval_js, code})
      def webview_eval_js(scene, code), do: record({:eval_js, scene, code})
      def webview_post_message(json), do: record({:post_message, IO.iodata_to_binary(json)})

      def webview_post_message(scene, json),
        do: record({:post_message, scene, IO.iodata_to_binary(json)})

      def dismiss_keyboard, do: record(:dismiss_keyboard)
      def dismiss_keyboard(scene), do: record({:dismiss_keyboard, scene})
    end
    """)

    primary = Mob.Socket.new(Mob.Screen, platform: :ios)
    second = Mob.Socket.put_mob(primary, :scene, "B")

    expect = fn call ->
      receive do
        ^call -> :ok
        other -> raise "expected #{inspect(call)}, got #{inspect(other)}"
      after
        1_000 -> raise "expected #{inspect(call)}, got nothing"
      end
    end

    ^second = Mob.WebView.eval_js(second, "go()")
    expect.({:eval_js, "B", "go()"})
    ^primary = Mob.WebView.eval_js(primary, "go()")
    expect.({:eval_js, "go()"})

    Mob.WebView.post_message(second, %{"n" => 1})
    expect.({:post_message, "B", ~s({"n":1})})
    Mob.WebView.post_message(primary, %{"n" => 1})
    expect.({:post_message, ~s({"n":1})})

    ^second = Mob.Keyboard.dismiss(second)
    expect.({:dismiss_keyboard, "B"})
    ^primary = Mob.Keyboard.dismiss(primary)
    expect.(:dismiss_keyboard)

    IO.puts("window_calls_ok")
    '''

    assert_isolated_success(script, "window_calls_ok")
  end

  defp assert_isolated_success(script, marker) do
    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ marker
  end
end
