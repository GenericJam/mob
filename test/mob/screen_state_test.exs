defmodule Mob.ScreenStateTest do
  use ExUnit.Case, async: false

  # In-process SQLite repo used only in this test file.
  defmodule TestRepo do
    use Ecto.Repo, otp_app: :mob_screen_state_test, adapter: Ecto.Adapters.SQLite3
  end

  @create_table """
  CREATE TABLE IF NOT EXISTS mob_screen_states (
    key      TEXT    PRIMARY KEY NOT NULL,
    vsn      INTEGER NOT NULL DEFAULT 0,
    data     BLOB    NOT NULL,
    updated_at INTEGER NOT NULL
  )
  """

  setup do
    db = System.tmp_dir!() <> "/mob_ss_test_#{System.unique_integer([:positive])}.db"
    Application.put_env(:mob_screen_state_test, TestRepo, database: db, pool_size: 1)
    Application.put_env(:mob, :repo, TestRepo)

    start_supervised!(TestRepo)
    TestRepo.query!(@create_table, [])

    on_exit(fn ->
      Application.delete_env(:mob, :repo)
      File.rm(db)
    end)

    socket = Mob.Socket.new(FakeScreen)
    {:ok, socket: socket}
  end

  # ── Minimal screen stubs ─────────────────────────────────────────────────

  defmodule PersistScreen do
    use Mob.Screen, vsn: 1

    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_), do: %{}
  end

  defmodule MigratingScreen do
    use Mob.Screen, vsn: 2

    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_), do: %{}
    def dump_state(assigns), do: Map.take(assigns, [:count])
    def load_state(2, stored), do: stored
    def load_state(1, stored), do: Map.put(stored, :count, stored[:count] || 0)
    def load_state(_, _), do: %{}
  end

  defmodule KeyedScreen do
    use Mob.Screen, vsn: 1

    def mount(_p, _s, socket), do: {:ok, socket}
    def render(_), do: %{}
    def screen_key(assigns), do: "#{__MODULE__}:#{assigns.user_id}"
  end

  defmodule FakeScreen do
    def __mob_vsn__, do: 0
    def __mob_persist__, do: false
    def dump_state(assigns), do: assigns
    def load_state(_vsn, stored), do: stored
  end

  # ── dump/2 ────────────────────────────────────────────────────────────────

  describe "dump/2" do
    test "writes assigns to the database", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 7)
      assert :ok = Mob.ScreenState.dump(PersistScreen, socket)
      %{rows: [[vsn, blob]]} = TestRepo.query!("SELECT vsn, data FROM mob_screen_states", [])
      assert vsn == 1
      assert is_binary(blob) and byte_size(blob) > 0
    end

    test "upserts on second write", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 1)
      Mob.ScreenState.dump(PersistScreen, socket)
      socket2 = Mob.Socket.assign(socket, count: 99)
      Mob.ScreenState.dump(PersistScreen, socket2)
      %{rows: rows} = TestRepo.query!("SELECT count(*) FROM mob_screen_states", [])
      assert [[1]] = rows
    end

    test "strips PIDs and references from assigns", %{socket: socket} do
      socket = Mob.Socket.assign(socket, pid: self(), ref: make_ref(), count: 42)
      assert :ok = Mob.ScreenState.dump(PersistScreen, socket)
      {:ok, _vsn, raw} = Mob.ScreenState.load(PersistScreen, socket)
      refute Map.has_key?(raw, :pid)
      refute Map.has_key?(raw, :ref)
      assert raw[:count] == 42
    end

    test "uses screen_key/1 when defined", %{socket: socket} do
      socket = Mob.Socket.assign(socket, user_id: 99)
      Mob.ScreenState.dump(KeyedScreen, socket)
      %{rows: [[key]]} = TestRepo.query!("SELECT key FROM mob_screen_states", [])
      assert key == "#{KeyedScreen}:99"
    end

    test "is a no-op when repo is not configured", %{socket: socket} do
      Application.delete_env(:mob, :repo)
      assert :ok = Mob.ScreenState.dump(PersistScreen, socket)
    after
      Application.put_env(:mob, :repo, TestRepo)
    end
  end

  # ── load/2 ────────────────────────────────────────────────────────────────

  describe "load/2" do
    test "returns not_found when no state is saved", %{socket: socket} do
      assert :not_found = Mob.ScreenState.load(PersistScreen, socket)
    end

    test "returns stored assigns after dump", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 5, label: "hello")
      Mob.ScreenState.dump(PersistScreen, socket)
      assert {:ok, 1, raw} = Mob.ScreenState.load(PersistScreen, socket)
      assert raw[:count] == 5
      assert raw[:label] == "hello"
    end

    test "returns stored vsn for migration", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 3)
      Mob.ScreenState.dump(MigratingScreen, socket)
      assert {:ok, 2, _raw} = Mob.ScreenState.load(MigratingScreen, socket)
    end

    test "returns not_found when repo is not configured", %{socket: socket} do
      Application.delete_env(:mob, :repo)
      assert :not_found = Mob.ScreenState.load(PersistScreen, socket)
    after
      Application.put_env(:mob, :repo, TestRepo)
    end
  end

  # ── delete/2 ─────────────────────────────────────────────────────────────

  describe "delete/2" do
    test "removes the record", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 1)
      Mob.ScreenState.dump(PersistScreen, socket)
      Mob.ScreenState.delete(PersistScreen, socket)
      assert :not_found = Mob.ScreenState.load(PersistScreen, socket)
    end

    test "is a no-op when no record exists", %{socket: socket} do
      assert :ok = Mob.ScreenState.delete(PersistScreen, socket)
    end
  end

  # ── use Mob.Screen, vsn: ─────────────────────────────────────────────────

  describe "use Mob.Screen, vsn:" do
    test "__mob_vsn__/0 returns declared version" do
      assert PersistScreen.__mob_vsn__() == 1
      assert MigratingScreen.__mob_vsn__() == 2
    end

    test "__mob_persist__/0 is true when vsn > 0" do
      assert PersistScreen.__mob_persist__() == true
    end

    test "__mob_persist__/0 is false by default" do
      defmodule NoPersistScreen do
        use Mob.Screen

        def mount(_p, _s, socket), do: {:ok, socket}
        def render(_), do: %{}
      end

      assert NoPersistScreen.__mob_persist__() == false
    end

    test "persist: true enables persistence without vsn" do
      defmodule ExplicitPersistScreen do
        use Mob.Screen, persist: true

        def mount(_p, _s, socket), do: {:ok, socket}
        def render(_), do: %{}
      end

      assert ExplicitPersistScreen.__mob_persist__() == true
      assert ExplicitPersistScreen.__mob_vsn__() == 0
    end

    test "default dump_state returns assigns unchanged" do
      socket = Mob.Socket.assign(Mob.Socket.new(PersistScreen), x: 1)
      assert PersistScreen.dump_state(socket.assigns) == %{x: 1}
    end

    test "default load_state returns stored map unchanged" do
      stored = %{count: 42}
      assert PersistScreen.load_state(1, stored) == stored
    end

    test "custom dump_state is used during dump", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 9, ignored: "drop me")
      Mob.ScreenState.dump(MigratingScreen, socket)
      {:ok, _vsn, raw} = Mob.ScreenState.load(MigratingScreen, socket)
      assert raw == %{count: 9}
      refute Map.has_key?(raw, :ignored)
    end

    test "load_state migration runs on version mismatch", %{socket: socket} do
      socket = Mob.Socket.assign(socket, count: 5)
      # Manually write a vsn=1 record to simulate old app data
      key = to_string(MigratingScreen)
      data = :erlang.term_to_binary(%{count: 5})
      ts = System.system_time(:second)

      TestRepo.query!(
        "INSERT INTO mob_screen_states (key, vsn, data, updated_at) VALUES (?, ?, ?, ?)",
        [key, 1, data, ts]
      )

      {:ok, stored_vsn, raw} = Mob.ScreenState.load(MigratingScreen, socket)
      assert stored_vsn == 1
      migrated = MigratingScreen.load_state(stored_vsn, raw)
      assert migrated == %{count: 5}
    end
  end
end
