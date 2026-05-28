defmodule Mob.CertsTest do
  use ExUnit.Case, async: false

  # `:public_key`'s cacert store is global to the BEAM; tests can't be
  # async since they mutate it.
  #
  # `:public_key.cacerts_clear/0` returns the in-memory cache to empty,
  # but `:public_key.cacerts_get/0` will then re-load from the OS trust
  # store on the next call. On macOS that means ~150 system certs come
  # back — the test host is never in a "no certs at all" state. We
  # therefore can't assert `loaded?/0 == false` before loading. Instead,
  # the happy-path tests prove the wrapper added *our* cert by looking
  # for ISRG Root X1's subject in the resulting list.

  alias Mob.Certs

  # ISRG Root X1 (Let's Encrypt). Public root cert, expires 2035, embedded
  # here so the test suite doesn't need a fixture file or a network fetch.
  @test_pem """
  -----BEGIN CERTIFICATE-----
  MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
  TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
  cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
  WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
  ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
  MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
  h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
  0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
  A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
  T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
  B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
  B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
  KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
  OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
  jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
  qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
  rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
  HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
  hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
  ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
  3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
  NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
  ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
  TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
  jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
  oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
  4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
  mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
  emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
  -----END CERTIFICATE-----
  """

  # Distinctive substring in ISRG Root X1's subject DN (UTF-8 bytes for
  # "ISRG Root X1"). Used to verify the test cert actually landed in
  # `:public_key.cacerts_get/0`.
  @isrg_subject_marker "ISRG Root X1"

  setup do
    # Elixir 1.19+ strips unused OTP apps from the code path. mob now lists
    # :public_key in extra_applications so users get it transitively, but
    # the test runtime needs an explicit ensure_all_started before tests
    # can call :public_key.* directly.
    {:ok, _} = Application.ensure_all_started(:public_key)

    path =
      Path.join(System.tmp_dir!(), "mob_certs_test_#{System.unique_integer([:positive])}.pem")

    pem =
      @test_pem |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.join("\n")

    File.write!(path, pem <> "\n")

    on_exit(fn -> _ = File.rm(path) end)

    {:ok, pem_path: path}
  end

  describe "load_cacerts/1" do
    test "returns :ok and adds the cert to :public_key's store", %{pem_path: path} do
      assert :ok = Certs.load_cacerts(path)
      assert isrg_in_store?()
    end

    test "is idempotent across repeated loads", %{pem_path: path} do
      assert :ok = Certs.load_cacerts(path)
      first_count = isrg_count()

      assert :ok = Certs.load_cacerts(path)
      # Re-loading the same PEM doesn't duplicate the same cert.
      assert isrg_count() == first_count
    end

    test "returns {:error, reason} for a non-existent path" do
      assert {:error, _} = Certs.load_cacerts("/does/not/exist.pem")
    end

    test "returns {:error, reason} for a path that isn't a PEM" do
      not_pem = Path.join(System.tmp_dir!(), "mob_certs_not_a_pem.txt")
      File.write!(not_pem, "this is not a certificate\n")
      on_exit(fn -> File.rm(not_pem) end)

      assert {:error, _} = Certs.load_cacerts(not_pem)
    end
  end

  describe "load_cacerts!/1" do
    test "returns :ok on success", %{pem_path: path} do
      assert :ok = Certs.load_cacerts!(path)
      assert isrg_in_store?()
    end

    test "raises on a non-existent path" do
      assert_raise RuntimeError, ~r/Mob.Certs.load_cacerts!\/1 failed/, fn ->
        Certs.load_cacerts!("/does/not/exist.pem")
      end
    end
  end

  describe "loaded?/0" do
    test "true after a successful load", %{pem_path: path} do
      :ok = Certs.load_cacerts(path)
      assert Certs.loaded?()
    end
  end

  # The host (Mac/Linux) usually has OS certs that auto-load, so we don't
  # try to assert `loaded?/0 == false` here — that's an Android-specific
  # behavior covered by integration testing on-device. What we can verify
  # is that *our* cert ends up in the store.
  defp isrg_in_store? do
    isrg_count() > 0
  end

  # `:public_key.cacerts_get/0` returns `[{:cert, DerBin, OtpCert} | ...]`.
  # Look for the marker in the DER blob — ASN.1 encodes the cert's subject
  # CN as PrintableString or UTF8String, so the literal "ISRG Root X1"
  # appears as plain ASCII bytes embedded in the DER.
  defp isrg_count do
    :public_key.cacerts_get()
    |> Enum.count(fn {:cert, der, _otp_cert} ->
      :binary.match(der, @isrg_subject_marker) != :nomatch
    end)
  rescue
    _ -> 0
  end
end
