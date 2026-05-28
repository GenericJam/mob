defmodule Mob.Certs do
  @moduledoc """
  CA-certificate loading for mob apps. Companion to `Mob.DNS` — same
  shape: a small wrapper documenting and working around something OTP
  assumes about the OS that Android doesn't satisfy.

  ## Why this exists

  `:public_key.cacerts_load/0` looks for a system CA bundle at one of
  the distro paths it knows (`/etc/ssl/certs/ca-certificates.crt`,
  `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/cert.pem`, …). On
  Android none of those exist — the system trust store lives behind a
  Java API that BEAM's `:public_key` doesn't reach. Subsequent calls
  to `:public_key.cacerts_get/0` therefore raise with `no_cacerts_found`,
  and any library that consults it (Req → Mint → `:ssl`, Finch, anything
  using OTP-26+ default `:ssl` opts) crashes on the first TLS connect.

  Adding insult: in some OTP versions `pubkey_os_cacerts.conv_error_reason/1`
  has no clause for `no_cacerts_found`, so the surface error is a
  `FunctionClauseError` — opaque to the unsuspecting reader. The fix is
  the same regardless: load a PEM bundle into `:public_key` once at boot.

  Hex itself bakes its own DER bundle, so the BEAM can `mix.install/2`
  without this fix; every other Elixir HTTP library can't.

  ## What to do

  Bundle a CA PEM in your app priv (e.g. copy `castore`'s `cacerts.pem`)
  and call `Mob.Certs.load_cacerts!/1` once at boot, *before* anything
  tries TLS:

      def on_start do
        Mob.Certs.load_cacerts!(Application.app_dir(:my_app, "priv/cacerts.pem"))
        # …rest of startup…
      end

  The bundle is the app's choice — security: who do you trust. The
  conventional source is the `castore` hex package (a current Mozilla
  trust store), copied into `priv/` at build time.

  iOS isn't affected — Darwin exposes the trust store via the paths
  Erlang knows about, so `:public_key.cacerts_load/0` (no arg) works
  there. Calling `load_cacerts!/1` on iOS at the bundled-PEM path is a
  harmless extra load; cross-platform apps can call it unconditionally.

  ## Scope

  - Loads CA certificates from a PEM file path.
  - Wraps `:public_key.cacerts_load/1` so failure shapes are predictable
    (`{:error, reason}` rather than the OTP-version-dependent
    `FunctionClauseError` you sometimes see otherwise).
  - Pure Elixir. No NIF, no platform branch.
  """

  @doc """
  Load CA certs from a PEM file into Erlang's `:public_key` cacert store.

  Idempotent: re-loading the same bundle just re-merges its certs into
  the in-process trust store; no duplication, no error.

  Returns `:ok` on success or `{:error, reason}` if the file can't be
  read or parsed.

      iex> Mob.Certs.load_cacerts("priv/cacerts.pem")
      :ok

  """
  @spec load_cacerts(Path.t()) :: :ok | {:error, term()}
  def load_cacerts(path) when is_binary(path) do
    case :public_key.cacerts_load(String.to_charlist(path)) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Same as `load_cacerts/1`, but raises on failure.

  Use this at boot when failing-to-load is unrecoverable — i.e. when the
  app needs HTTPS at all to function. Most callers want this variant.
  """
  @spec load_cacerts!(Path.t()) :: :ok
  def load_cacerts!(path) when is_binary(path) do
    case load_cacerts(path) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Mob.Certs.load_cacerts!/1 failed for #{inspect(path)}: " <>
                inspect(reason)
    end
  end

  @doc """
  True if any CA certificates are loaded in the `:public_key` store.

  Useful for diagnostics and tests. `:public_key.cacerts_get/0` raises
  when nothing is loaded; `loaded?/0` catches that and returns `false`
  instead.
  """
  @spec loaded?() :: boolean()
  def loaded? do
    case :public_key.cacerts_get() do
      [_ | _] -> true
      [] -> false
    end
  rescue
    _ -> false
  end
end
