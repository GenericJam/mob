# Source-contract test: MobBridge.shareFile is cached optionally so older
# generated apps without the method still boot and degrade to :unsupported.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.AndroidShareFileTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  setup_all do
    {:ok, zig: File.read!(Path.join(@root, "android/jni/mob_nif.zig"))}
  end

  test "shareFile is cached with cacheOptional, never cacheRequired", %{zig: zig} do
    assert zig =~
             ~s|cacheOptional(jenv, "shareFile", "(JLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)V", &Bridge.share_file)|

    refute zig =~ ~s|cacheRequired(jenv, "shareFile"|
  end
end
