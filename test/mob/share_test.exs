defmodule Mob.ShareTest do
  # async: false because the relative-path test calls File.cd!/2.
  use ExUnit.Case, async: false

  defmodule Screen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "hi"}, children: []}
  end

  defmodule FakeNif do
    @moduledoc false

    def share_file(path, mime, title) do
      send(:persistent_term.get({__MODULE__, :test}), {:nif_share_file, path, mime, title})
      :persistent_term.get({__MODULE__, :reply}, :ok)
    end
  end

  setup do
    :persistent_term.put({FakeNif, :test}, self())
    :persistent_term.put({FakeNif, :reply}, :ok)

    on_exit(fn ->
      :persistent_term.erase({FakeNif, :test})
      :persistent_term.erase({FakeNif, :reply})
    end)

    %{socket: Mob.Socket.new(Screen, platform: :no_render)}
  end

  @tag :tmp_dir
  test "derives default mime for .pdf, upper-case .MID, and unknown extensions", %{
    socket: socket,
    tmp_dir: tmp
  } do
    pdf = Path.join(tmp, "score.pdf")
    mid = Path.join(tmp, "DEMO.MID")
    raw = Path.join(tmp, "blob.unknownext")
    Enum.each([pdf, mid, raw], &File.write!(&1, "data"))

    assert Mob.Share.__file__(socket, pdf, [], FakeNif) == socket
    assert_received {:nif_share_file, ^pdf, "application/pdf", "score.pdf"}

    Mob.Share.__file__(socket, mid, [], FakeNif)
    assert_received {:nif_share_file, ^mid, "audio/midi", "DEMO.MID"}

    Mob.Share.__file__(socket, raw, [], FakeNif)
    assert_received {:nif_share_file, ^raw, "application/octet-stream", "blob.unknownext"}
  end

  @tag :tmp_dir
  test "passes explicit mime and non-BMP title through", %{socket: socket, tmp_dir: tmp} do
    path = Path.join(tmp, "take.bin")
    File.write!(path, "bytes")

    result =
      Mob.Share.__file__(
        socket,
        path,
        [mime: "audio/x-custom", title: "Riff 🎸"],
        FakeNif
      )

    assert result == socket
    assert_received {:nif_share_file, ^path, "audio/x-custom", "Riff 🎸"}
  end

  @tag :tmp_dir
  test "resolves a relative path against cwd and defaults title to basename", %{
    socket: socket,
    tmp_dir: tmp
  } do
    File.mkdir_p!(Path.join(tmp, "exports"))
    File.write!(Path.join(tmp, "exports/chart.musicxml"), "<score/>")

    File.cd!(tmp, fn ->
      expected = Path.join(File.cwd!(), "exports/chart.musicxml")
      assert Mob.Share.__file__(socket, "exports/chart.musicxml", [], FakeNif) == socket

      assert_received {:nif_share_file, ^expected, "application/vnd.recordare.musicxml+xml",
                       "chart.musicxml"}
    end)
  end

  @tag :tmp_dir
  test "missing file sends :not_found and does not call the NIF", %{
    socket: socket,
    tmp_dir: tmp
  } do
    missing = Path.join(tmp, "missing.pdf")

    assert Mob.Share.__file__(socket, missing, [], FakeNif) == socket
    assert_received {:mob_share, :error, :not_found}
    refute_received {:nif_share_file, _, _, _}
  end

  @tag :tmp_dir
  test "directory path sends :not_found and does not call the NIF", %{
    socket: socket,
    tmp_dir: tmp
  } do
    assert Mob.Share.__file__(socket, tmp, [], FakeNif) == socket
    assert_received {:mob_share, :error, :not_found}
    refute_received {:nif_share_file, _, _, _}
  end

  @tag :tmp_dir
  test "NIF {:error, :unsupported} delivers {:mob_share, :error, :unsupported}", %{
    socket: socket,
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "note.txt")
    File.write!(path, "hello")
    :persistent_term.put({FakeNif, :reply}, {:error, :unsupported})

    assert Mob.Share.__file__(socket, path, [], FakeNif) == socket
    assert_received {:nif_share_file, ^path, "text/plain", "note.txt"}
    assert_received {:mob_share, :error, :unsupported}
  end

  @tag :tmp_dir
  test "NIF :ok sends no message", %{socket: socket, tmp_dir: tmp} do
    path = Path.join(tmp, "note.txt")
    File.write!(path, "hello")

    assert Mob.Share.__file__(socket, path, [], FakeNif) == socket
    assert_received {:nif_share_file, ^path, "text/plain", "note.txt"}
    refute_received {:mob_share, _, _}
  end

  @tag :tmp_dir
  test "raises ArgumentError on unknown option, invalid mime, or empty title", %{
    socket: socket,
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "note.txt")
    File.write!(path, "hello")

    assert_raise ArgumentError, fn ->
      Mob.Share.__file__(socket, path, [unknown: true], FakeNif)
    end

    assert_raise ArgumentError, fn ->
      Mob.Share.__file__(socket, path, [mime: "invalid"], FakeNif)
    end

    assert_raise ArgumentError, fn ->
      Mob.Share.__file__(socket, path, [mime: ""], FakeNif)
    end

    assert_raise ArgumentError, fn ->
      Mob.Share.__file__(socket, path, [title: ""], FakeNif)
    end
  end
end
