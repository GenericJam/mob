defmodule Mob.Diag do
  @moduledoc """
  Runtime diagnostics that run inside a Mob app's BEAM. Designed to be
  invoked via Erlang RPC from a developer's machine to inspect the
  actual state of a deployed app.

  Pairs with mob_dev's tooling — `mix mob.verify_strip` calls into
  `verify_loaded_modules/0`. Kept in the `mob` library (not `mob_dev`)
  so the functions are present in every shipped app, not just at build
  time on the developer's machine.

  Don't expand the API surface here without thinking — anything added
  is permanently shipped to every Mob app and a permanent target for
  remote-execution if dist credentials leak.
  """

  @type load_failure :: %{module: module(), reason: term()}
  @type load_report :: %{
          total: non_neg_integer(),
          loaded: non_neg_integer(),
          failed: [load_failure()],
          elapsed_us: non_neg_integer(),
          otp_root: String.t() | nil
        }

  @doc """
  Force-load every `.beam` file under the running app's OTP tree and
  report any that fail. Used by `mix mob.verify_strip` to validate
  that an aggressive strip didn't remove a module something else
  needed.

  Walks all entries in `:code.get_path/0`, finds the OTP root from
  the first matching `.../otp/lib/...` path, and enumerates `.beam`
  files under it.

  Returns `t:load_report/0`. Failures usually mean a stripped lib
  contained a transitive dependency of a kept module.
  """
  @spec verify_loaded_modules() :: load_report()
  def verify_loaded_modules do
    started = System.monotonic_time(:microsecond)

    beams = enumerate_beams()
    {ok_count, failures} = Enum.reduce(beams, {0, []}, &try_load/2)

    %{
      total: length(beams),
      loaded: ok_count,
      failed: Enum.reverse(failures),
      elapsed_us: System.monotonic_time(:microsecond) - started,
      otp_root: detect_otp_root()
    }
  end

  defp enumerate_beams do
    case detect_otp_root() do
      nil -> []
      root -> Path.wildcard(Path.join(root, "**/*.beam"))
    end
  end

  defp detect_otp_root do
    :code.get_path()
    |> Enum.map(&to_string/1)
    |> Enum.find(&String.contains?(&1, "/otp/lib/"))
    |> case do
      nil -> nil
      path -> path |> String.split("/otp/lib/") |> List.first() |> Kernel.<>("/otp")
    end
  end

  defp try_load(beam_path, {ok_count, failures}) do
    module = beam_path |> Path.basename(".beam") |> String.to_atom()

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        {ok_count + 1, failures}

      {:error, reason} ->
        {ok_count, [%{module: module, reason: reason} | failures]}
    end
  end

  @type loaded_snapshot :: %{
          loaded: [module()],
          loaded_count: non_neg_integer(),
          shipped_count: non_neg_integer(),
          unloaded_in_bundle: [module()],
          otp_root: String.t() | nil,
          captured_at: DateTime.t()
        }

  @doc """
  Snapshot of what's currently loaded in the running BEAM, plus
  what's shipped-but-never-loaded (the empirical strip candidates).

  In interactive mode (Mob's default), a module is loaded only when
  something calls into it. So the loaded set after a representative
  user session is "what the app actually needs." Anything in the
  bundle but not in the loaded set is a strong strip candidate.

  Better than tracing for our purposes: zero overhead, no rate-limit
  worries, no risk of mailbox-overflowing a busy app.

  Workflow:

    1. Deploy the app
    2. User exercises every flow they care about
    3. RPC `Mob.Diag.loaded_snapshot/0` from a Mix task
    4. Cross-reference `:unloaded_in_bundle` with the static audit:
       shipped + statically-reachable + never-loaded = high-confidence
       strip candidates.

  Caveats: a flow that wasn't exercised won't show up. Run after a
  thorough session, not after just opening the app.
  """
  @spec loaded_snapshot() :: loaded_snapshot()
  def loaded_snapshot do
    loaded = :code.all_loaded() |> Enum.map(fn {m, _path} -> m end) |> MapSet.new()

    shipped =
      enumerate_beams()
      |> Enum.map(fn beam -> beam |> Path.basename(".beam") |> String.to_atom() end)
      |> MapSet.new()

    %{
      loaded: MapSet.to_list(loaded) |> Enum.sort(),
      loaded_count: MapSet.size(loaded),
      shipped_count: MapSet.size(shipped),
      unloaded_in_bundle: MapSet.difference(shipped, loaded) |> Enum.sort(),
      otp_root: detect_otp_root(),
      captured_at: DateTime.utc_now()
    }
  end
end
