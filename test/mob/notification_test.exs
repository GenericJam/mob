defmodule Mob.NotificationTest do
  use ExUnit.Case, async: true

  alias Mob.Notification

  defp decode!(envelope), do: {:ok, _} = Notification.decode(JSON.encode!(envelope))

  describe "decode/1" do
    test "a foreground arrival from the iOS delegate" do
      assert {:ok, notification} =
               decode!(%{
                 "id" => "reminder_1",
                 "title" => "Check in",
                 "body" => "Time to check in",
                 "source" => "local",
                 "presentation" => "foreground",
                 "action" => nil,
                 "data" => %{"screen" => "reminders", "count" => 3}
               })

      assert notification == %{
               id: "reminder_1",
               title: "Check in",
               body: "Time to check in",
               source: :local,
               presentation: :foreground,
               action: nil,
               data: %{screen: "reminders", count: 3}
             }
    end

    test "a tap keeps its action identifier" do
      assert {:ok, %{presentation: :tap, action: "reply"}} =
               decode!(%{"presentation" => "tap", "action" => "reply", "data" => %{}})
    end

    test "a tap without an action is the default action" do
      assert {:ok, %{presentation: :tap, action: "default"}} =
               decode!(%{"presentation" => "tap", "data" => %{}})
    end

    test "a foreground arrival never carries an action" do
      assert {:ok, %{presentation: :foreground, action: nil}} =
               decode!(%{"presentation" => "foreground", "action" => "default"})
    end

    # The taps that predate the field (older app-owned MainActivity code, the
    # iOS mob_set_launch_notification_json hook) reach the same entry without it.
    # The one older caller that sends arrivals, an app-owned MobFirebaseService,
    # has to add "presentation": "foreground" (CHANGELOG upgrade step).
    test "an envelope without presentation is a tap" do
      assert {:ok, %{presentation: :tap, action: "default", source: :local}} =
               decode!(%{
                 "id" => "n1",
                 "title" => "t",
                 "body" => "b",
                 "source" => "local",
                 "data" => %{"thread_id" => "42"}
               })
    end

    test "source is :push only for \"push\"" do
      assert {:ok, %{source: :push}} = decode!(%{"source" => "push"})
      assert {:ok, %{source: :local}} = decode!(%{"source" => "remote"})
      assert {:ok, %{source: :local}} = decode!(%{})
    end

    test "data keys become atoms; nested values stay as JSON decodes them" do
      assert {:ok, %{data: data}} =
               decode!(%{
                 "data" => %{
                   "thread" => %{"id" => "42", "tags" => ["a", "b"]},
                   "urgent" => true,
                   "score" => 1.5,
                   "nothing" => nil
                 }
               })

      assert data == %{
               thread: %{"id" => "42", "tags" => ["a", "b"]},
               urgent: true,
               score: 1.5,
               nothing: nil
             }
    end

    test "missing or non-map data is an empty map" do
      assert {:ok, %{data: %{}}} = decode!(%{})
      assert {:ok, %{data: %{}}} = decode!(%{"data" => "oops"})
    end

    test "non-string text fields are nil" do
      assert {:ok, %{id: nil, title: nil, body: nil}} =
               decode!(%{"id" => 7, "title" => nil, "body" => ["x"]})
    end

    test "a payload that is not JSON is an error, not a raise" do
      assert Notification.decode(~s({"title": "unterminated)) == {:error, :invalid_json}
      assert Notification.decode("") == {:error, :invalid_json}
    end

    test "JSON that is not an object is an error" do
      assert Notification.decode(~s(["a"])) == {:error, :not_an_object}
      assert Notification.decode("42") == {:error, :not_an_object}
    end

    # String.to_atom/1 raises past 255 characters; raising in the router would
    # take every screen down.
    test "a data key too long to be an atom is an error, not a raise" do
      too_long = String.duplicate("k", 256)

      assert Notification.decode(JSON.encode!(%{"data" => %{too_long => 1}})) ==
               {:error, :data_key_too_long}

      longest = String.duplicate("é", 255)
      assert {:ok, %{data: data}} = decode!(%{"data" => %{longest => 1}})
      assert data == %{String.to_atom(longest) => 1}
    end
  end
end
