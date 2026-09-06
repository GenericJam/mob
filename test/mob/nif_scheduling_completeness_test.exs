defmodule Mob.NifSchedulingCompletenessTest do
  @moduledoc """
  Every registered iOS NIF is classified, so adding one without deciding how it
  schedules fails the build.

  `input_nif_scheduling_test.exs` iterates hand-written lists of NIFs we
  remembered. It cannot fail for one nobody thought of — which is how MOB-160
  flagged nine and left eighteen, and how MOB-164 then flagged two that do not
  block at all. Enumeration is not enforcement.

  This closes the loop from the other side: the union of the lists below must
  equal the registration table exactly. A new NIF is a test failure until
  someone says which bucket it belongs in.

  The classification cannot be derived by grepping — that is the mistake worth
  not repeating. `audio_set_volume` contains `dispatch_sync`, yet it never
  blocks a scheduler: the sync is nested inside a `dispatch_async` block, so it
  runs on the main thread. Deciding requires reading the body.
  """
  use ExUnit.Case, async: true

  @ios Path.expand("../../ios/mob_nif.m", __DIR__)

  # Waits on the main thread — dispatch_sync at the top level, a semaphore, or
  # a sleep. Must be IO_BOUND: the scheduler is parked waiting on another
  # thread, not computing.
  @blocks_ui_thread ~w(
    audio_output_level ax_action ax_action_at_xy battery_level clear_text
    clipboard_get color_scheme delete_backward device_battery_state
    device_foreground device_orientation key_press long_press_xy resolve_ipv4
    safe_area screen_info scroll_info scroll_to set_theme swipe_xy tap tap_xy
    type_text webview_can_go_back
  )

  # Does real work on the calling thread — tree walks, JSON, image encoding.
  # CPU_BOUND: computing, not waiting.
  @cpu_heavy ~w(
    element_frames native_stats sample_region screenshot set_root
    set_transition ui_debug ui_paint_debug ui_tree ui_view_tree
  )

  # Returns promptly. Includes the ones that LOOK blocking: audio_set_volume
  # and audio_stop_playback both contain dispatch_sync, nested inside a
  # dispatch_async, so the scheduler thread never waits.
  @returns_promptly ~w(
    action_sheet_show alert_show audio_input_level audio_output_status
    audio_play audio_play_at audio_set_volume audio_start_input_metering
    audio_start_recording audio_stop_input_metering audio_stop_playback
    audio_stop_recording capabilities clear_taps clipboard_put
    deregister_component device_keep_awake device_lock_orientation
    device_low_power_mode device_model device_network_state device_os_version
    device_set_dispatcher device_thermal_state exit_app files_pick haptic log
    motion_start motion_stop native_stats_enable open_settings open_url
    platform register_component register_tap request_permission share_text
    storage_dir storage_external_files_dir storage_save_to_media_store
    storage_save_to_photo_library take_launch_notification take_opened_document
    toast_show torch tts_speak tts_stop vendor_usb_bulk_write vendor_usb_close
    vendor_usb_list_devices vendor_usb_open vendor_usb_request_permission
    vendor_usb_start_reading vendor_usb_stop_reading webview_eval_js
    webview_go_back webview_post_message
  )

  setup_all do
    entries =
      @ios
      |> File.read!()
      |> then(&Regex.scan(~r/\{"([a-z_0-9]+)",\s*\d+,\s*nif_\w+,\s*([A-Za-z_0-9]+)\}/, &1))
      |> Map.new(fn [_, name, flags] -> {name, flags} end)

    {:ok, entries: entries}
  end

  test "every registered NIF is classified", %{entries: entries} do
    classified = MapSet.new(@blocks_ui_thread ++ @cpu_heavy ++ @returns_promptly)
    registered = MapSet.new(Map.keys(entries))

    unclassified = MapSet.difference(registered, classified)

    assert MapSet.size(unclassified) == 0,
           """
           These NIFs are registered but not classified:

               #{unclassified |> Enum.sort() |> Enum.join(", ")}

           Decide how each schedules and add it to one of the lists in this
           file. Read the body — you cannot tell by grepping for dispatch_sync,
           because a sync nested inside a dispatch_async never blocks the
           scheduler. A NIF that waits on the main thread and is left on a
           normal scheduler stalls every process on the device.
           """

    stale = MapSet.difference(classified, registered)

    assert MapSet.size(stale) == 0,
           "classified but no longer registered: #{stale |> Enum.sort() |> Enum.join(", ")}"
  end

  test "anything that waits on the main thread is IO_BOUND", %{entries: entries} do
    for name <- @blocks_ui_thread do
      assert entries[name] =~ "IO_BOUND",
             "#{name} waits on the main thread but is #{entries[name]} — it stalls " <>
               "every process on the device for as long as it waits"
    end
  end

  test "anything that computes is CPU_BOUND", %{entries: entries} do
    for name <- @cpu_heavy do
      assert entries[name] =~ "CPU_BOUND", "#{name} is #{entries[name]}, expected CPU_BOUND"
    end
  end

  test "anything that returns promptly stays on a normal scheduler", %{entries: entries} do
    # The inverse matters as much. A dirty hop for a NIF that returns straight
    # away is pure overhead, and it makes the rule false of its own members —
    # which is exactly what MOB-164 did to audio_set_volume before this test.
    for name <- @returns_promptly do
      assert entries[name] == "0",
             "#{name} returns promptly but is flagged #{entries[name]} — a dirty " <>
               "scheduler hop buys nothing and contends for the single dirty IO slot"
    end
  end
end
