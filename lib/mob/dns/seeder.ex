defmodule Mob.DNS.Seeder do
  @moduledoc """
  Serialises `Mob.DNS.resolve/1`'s writes to `:inet_db`'s runtime host table.

  Replacing one host's entry is a read-modify-write spanning several
  `:inet_db` calls, so two resolves sharing an address would otherwise drop
  each other's names. A locally registered process is the lock: `:global.trans/3`
  keys its release on the node name captured at acquire time, and `Mob.Dist`
  renames the node when it starts distribution after boot, which leaves that
  lock held forever. Started on first use and unlinked, because `mob` has no
  supervision tree of its own and a resolve from a screen callback must not tie
  the seeder's life to that screen.
  """

  use GenServer

  @doc false
  @spec replace(charlist(), :inet.ip4_address()) :: :ok
  def replace(host, ip), do: call({:replace, host, ip}, 1)

  # `:infinity` like `:inet_db`'s own calls: a timed-out caller would exit
  # while its queued request still rewrote the table afterwards. `:noproc`
  # usually means `start/0` handed back a seeder that died before the call
  # reached it, so it gets one retry against a fresh seeder (replacing a
  # host is idempotent). Any other exit, and a second `:noproc`, propagates.
  defp call(request, retries) do
    {:ok, pid} = start()
    GenServer.call(pid, request, :infinity)
  catch
    :exit, {:noproc, _} when retries > 0 -> call(request, retries - 1)
  end

  @doc false
  @spec start() :: {:ok, pid()}
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:replace, host, ip}, _from, state) do
    replace_host(host, ip)
    {:reply, :ok, state}
  end

  # `:inet_db.add_host/2` is keyed by address: it replaces the name list
  # stored under `ip` and *appends* `ip` to each name's address list.
  # Calling it bare therefore leaves a host's stale address first (so
  # `:inet.getaddr/2` keeps returning it) and evicts every other host
  # already seeded under the same address. Rebuild both sides instead:
  # strip `host` from any other IPv4 entry, then seed `ip` with `host`
  # plus the names already sharing it. `get_rc/0` reports only the
  # runtime-added table, never the hosts file.
  defp replace_host(host, ip) do
    key = :inet_db.tolower(host)
    same_host? = &(:inet_db.tolower(&1) == key)
    entries = for {:host, {_, _, _, _} = addr, names} <- :inet_db.get_rc(), do: {addr, names}

    for {addr, names} <- entries, addr != ip, Enum.any?(names, same_host?) do
      case Enum.reject(names, same_host?) do
        [] -> :inet_db.del_host(addr)
        rest -> :inet_db.add_host(addr, rest)
      end
    end

    co_tenants =
      case List.keyfind(entries, ip, 0) do
        {^ip, names} -> Enum.reject(names, same_host?)
        nil -> []
      end

    :inet_db.add_host(ip, [host | co_tenants])
  end
end
