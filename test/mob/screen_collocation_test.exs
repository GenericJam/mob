defmodule Mob.ScreenCollocationTest do
  use ExUnit.Case, async: true

  test "use Mob.Screen compiles a sibling .mob.heex template into render/1" do
    dir =
      Path.join(System.tmp_dir!(), "mob_screen_collocation_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    module = Module.concat([:"CollocatedScreen#{System.unique_integer([:positive])}"])
    source = Path.join(dir, "collocated_screen.ex")
    template = Path.join(dir, "collocated_screen.mob.heex")

    File.write!(template, """
    <Column>
      <Text text={assigns.title} />
    </Column>
    """)

    File.write!(source, """
    defmodule #{inspect(module)} do
      use Mob.Screen

      def mount(_params, _session, socket), do: {:ok, socket}
    end
    """)

    Code.compile_file(source)

    assert %{
             type: :column,
             props: %{},
             children: [%{type: :text, props: %{text: "Hello"}, children: []}]
           } = module.render(%{title: "Hello"})
  end
end
