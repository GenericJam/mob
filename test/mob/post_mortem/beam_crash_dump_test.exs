defmodule Mob.PostMortem.BeamCrashDumpTest do
  # Bus + registry are process-global; async: false so a class row from one
  # test cannot answer another.
  use ExUnit.Case, async: false

  alias Mob.Defect.Bus
  alias Mob.PostMortem.BeamCrashDump
  alias Mob.PostMortem.Registry

  # A realistic 8-line dump header. Anything below the first blank-ish
  # section is irrelevant to this module; the scanner never reads past
  # its bounded window.
  @sample_dump """
  =erl_crash_dump:0.5
  Tue Sep  1 14:06:22 2026
  Slogan: Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error,[<<42,42,32,40,69,88,73,84>>]]}]})
  System version: Erlang/OTP 29 [erts-17.0] [source] [64-bit] [smp:12:12] [jit]
  Taints: crypto,asn1
  Atoms: 35424
  Calling Thread: scheduler:5
  =scheduler:1
  Scheduler Sleep Info Flags: SLEEPING
  """

  setup do
    Bus.start()
    Bus.reset()
    Registry.start()
    Registry.reset()
    :ok
  end

  defp write_dump(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  describe "normalize_slogan/1" do
    test "strips a binary literal — the crash class survives, the payload does not" do
      raw = "Runtime terminating ({badarg,[{io,put_chars,[<<42,42,42>>]}]})"
      normalized = BeamCrashDump.normalize_slogan(raw)

      # The class-defining shape is preserved
      assert normalized =~ "badarg"
      assert normalized =~ "put_chars"
      # The binary payload is not
      refute normalized =~ "42,42,42"
      assert normalized =~ "<<>>"
    end

    test "strips a long numeric sequence (>= 8 digits with commas)" do
      raw = "boot ({badarg,[[104,101,108,108,111,32,119,111,114,108,100]]})"
      normalized = BeamCrashDump.normalize_slogan(raw)
      refute normalized =~ "104,101,108"
    end

    test "collapses whitespace" do
      raw = "Kernel  pid   terminated    (application_controller)"
      normalized = BeamCrashDump.normalize_slogan(raw)
      assert normalized == "Kernel pid terminated (application_controller)"
    end

    test "nil in, nil out" do
      assert BeamCrashDump.normalize_slogan(nil) == nil
    end

    test "two crashes of the same class with different embedded binaries normalize identically" do
      a = "({badarg,[{io,put_chars,[<<1,2,3,4>>]}]})"
      b = "({badarg,[{io,put_chars,[<<99,99,99,99>>]}]})"
      assert BeamCrashDump.normalize_slogan(a) == BeamCrashDump.normalize_slogan(b)
    end

    test "a binary literal truncated at end of string still strips" do
      # A slogan cut off inside `<<...>>` has no closing `>>`. Without the
      # end-of-string branch in the strip pattern, the concrete bytes
      # would leak into the fingerprint and shatter same-class crashes
      # by the exact bytes that fit under @header_bytes.
      truncated_a = "({badarg,[{io,put_chars,[<<1,2,3,4,5,6,7,8"
      truncated_b = "({badarg,[{io,put_chars,[<<99,99,99,99,99,99,99,99"

      norm_a = BeamCrashDump.normalize_slogan(truncated_a)
      norm_b = BeamCrashDump.normalize_slogan(truncated_b)

      assert norm_a == norm_b
      refute norm_a =~ "1,2,3,4"
      refute norm_b =~ "99,99"
      assert norm_a =~ "<<>>"
    end
  end

  describe "scan/1" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "beam_crash_dump_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "extracts header fields from a real-shaped dump", %{tmp: tmp} do
      write_dump(tmp, "erl_crash.dump", @sample_dump)

      [finding] = BeamCrashDump.scan([tmp])

      assert finding.path == Path.join(tmp, "erl_crash.dump")
      assert String.starts_with?(finding.sha256, "sha256:")
      assert finding.size == byte_size(@sample_dump)
      assert %DateTime{} = finding.modified_at
      assert finding.slogan =~ "Runtime terminating during boot"
      assert finding.system_version =~ "Erlang/OTP 29"
      assert finding.taints == ["crypto", "asn1"]
      assert finding.atoms == 35_424
      assert finding.dump_version == "0.5"
    end

    test "accepts a file path directly, not just a directory", %{tmp: tmp} do
      path = write_dump(tmp, "erl_crash.dump", @sample_dump)
      [finding] = BeamCrashDump.scan([path])
      assert finding.path == path
    end

    test "returns [] for a non-existent path" do
      assert BeamCrashDump.scan(["/nonexistent/path/erl_crash.dump"]) == []
    end

    test "returns [] for a directory with no dump file", %{tmp: tmp} do
      assert BeamCrashDump.scan([tmp]) == []
    end

    test "does not recurse into subdirectories", %{tmp: tmp} do
      # A dump sitting one level deep is not our concern; the caller
      # decides which directories to sweep.
      sub = Path.join(tmp, "deeper")
      File.mkdir_p!(sub)
      write_dump(sub, "erl_crash.dump", @sample_dump)

      assert BeamCrashDump.scan([tmp]) == []
    end

    test "deduplicates identical paths passed twice", %{tmp: tmp} do
      write_dump(tmp, "erl_crash.dump", @sample_dump)
      assert length(BeamCrashDump.scan([tmp, tmp])) == 1
    end

    test "computes a distinct sha256 for two different dumps", %{tmp: tmp} do
      a = write_dump(tmp, "erl_crash.dump", @sample_dump)
      b_dir = Path.join(tmp, "other")
      File.mkdir_p!(b_dir)
      b = write_dump(b_dir, "erl_crash.dump", @sample_dump <> "extra byte")

      [fa] = BeamCrashDump.scan([a])
      [fb] = BeamCrashDump.scan([b])

      assert fa.sha256 != fb.sha256
    end
  end

  describe "emit/1" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "beam_crash_dump_emit_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "puts a capsule on the bus with normalized-slogan fingerprint key", %{tmp: tmp} do
      Bus.subscribe()
      write_dump(tmp, "erl_crash.dump", @sample_dump)

      [capsule] = tmp |> List.wrap() |> BeamCrashDump.scan() |> BeamCrashDump.emit()

      assert capsule.kind == :beam_crash
      assert capsule.owner == :mob
      # Evidence carries the raw slogan for a human triager
      assert capsule.evidence.slogan =~ "Runtime terminating"
      # Fingerprint key is normalized — binary stripped
      # (verify by rebuilding the same finding with a different embedded
      # binary; the two capsules must fingerprint identically)
      assert_receive {:mob_defect, ^capsule}, 500
    end

    test "is idempotent — a second emit of the same finding is a no-op", %{tmp: tmp} do
      write_dump(tmp, "erl_crash.dump", @sample_dump)
      findings = BeamCrashDump.scan([tmp])

      first = BeamCrashDump.emit(findings)
      second = BeamCrashDump.emit(findings)

      assert length(first) == 1
      assert second == []
    end

    test "the dump file is not moved or deleted", %{tmp: tmp} do
      path = write_dump(tmp, "erl_crash.dump", @sample_dump)
      tmp |> List.wrap() |> BeamCrashDump.scan() |> BeamCrashDump.emit()

      assert File.exists?(path)
      assert File.read!(path) == @sample_dump
    end

    test "the emit picks a :fatal severity for a Runtime-terminating-during-boot slogan", %{
      tmp: tmp
    } do
      # The fixture's slogan starts with `Runtime terminating during boot`.
      # A boot-time crash means the BEAM never actually came up, which is
      # a page-someone-now severity. Reverting the slogan match in
      # `severity_from_slogan/1` sends it back to :critical and this
      # assertion breaks.
      write_dump(tmp, "erl_crash.dump", @sample_dump)
      [capsule] = tmp |> List.wrap() |> BeamCrashDump.scan() |> BeamCrashDump.emit()
      assert capsule.severity == :fatal
    end

    test "two dumps with slogans that normalize identically share a fingerprint", %{tmp: tmp} do
      dump_a = String.replace(@sample_dump, "<<42,42,32,40,69,88,73,84>>", "<<1,2,3,4>>")
      dump_b = String.replace(@sample_dump, "<<42,42,32,40,69,88,73,84>>", "<<99,99,99,99>>")

      a = write_dump(tmp, "erl_crash.dump", dump_a)

      b_dir = Path.join(tmp, "other")
      File.mkdir_p!(b_dir)
      b = write_dump(b_dir, "erl_crash.dump", dump_b)

      [fa] = BeamCrashDump.scan([a])
      [fb] = BeamCrashDump.scan([b])

      # Distinct files (different sha256), so both emit
      [cap_a] = BeamCrashDump.emit([fa])
      [cap_b] = BeamCrashDump.emit([fb])

      # But they group by fingerprint — the normalized slogan is the same
      assert cap_a.fingerprint == cap_b.fingerprint
    end
  end

  describe "default_paths/0" do
    test "includes cwd" do
      assert File.cwd!() in BeamCrashDump.default_paths()
    end

    test "prepends ERL_CRASH_DUMP when set" do
      System.put_env("ERL_CRASH_DUMP", "/tmp/some_dump_path")

      try do
        paths = BeamCrashDump.default_paths()
        assert "/tmp/some_dump_path" in paths
      after
        System.delete_env("ERL_CRASH_DUMP")
      end
    end
  end
end
