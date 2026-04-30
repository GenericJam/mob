%% mob_nif.erl — Erlang NIF stub module.
%% ERL_NIF_INIT in mob_nif.c / mob_nif.m registers functions under this module name.
-module(mob_nif).
-export([platform/0,
         log/1, log/2,
         set_transition/1,
         set_root/1,
         register_tap/1,
         clear_taps/0,
         exit_app/0,
         safe_area/0,
         %% Device utilities (no permission required)
         haptic/1,
         clipboard_put/1,
         clipboard_get/0,
         share_text/1,
         %% Permissions
         request_permission/1,
         %% Biometric
         biometric_authenticate/1,
         %% Location
         location_get_once/0,
         location_start/1,
         location_stop/0,
         %% Camera
         camera_capture_photo/1,
         camera_capture_video/1,
         camera_start_preview/1,
         camera_stop_preview/0,
         %% Photo library
         photos_pick/2,
         %% File picker
         files_pick/1,
         %% Audio recording
         audio_start_recording/1,
         audio_stop_recording/0,
         %% Audio playback
         audio_play/2,
         audio_stop_playback/0,
         audio_set_volume/1,
         %% Motion sensors
         motion_start/2,
         motion_stop/0,
         %% QR / barcode scanner
         scanner_scan/1,
         %% Notifications
         notify_schedule/1,
         notify_cancel/1,
         notify_register_push/0,
         take_launch_notification/0,
         %% Storage
         storage_dir/1,
         storage_save_to_photo_library/1,
         storage_save_to_media_store/2,
         storage_external_files_dir/1,
         %% Alerts / overlays
         alert_show/3,
         action_sheet_show/2,
         toast_show/2,
         %% WebView
         webview_eval_js/1,
         webview_post_message/1,
         webview_can_go_back/0,
         webview_go_back/0,
         %% Native view components
         register_component/1,
         deregister_component/1,
         %% Background execution
         background_keep_alive/0,
         background_stop/0,
         %% Device state
         battery_level/0,
         %% Device lifecycle (Mob.Device)
         device_set_dispatcher/1,
         device_battery_state/0,
         device_thermal_state/0,
         device_low_power_mode/0,
         device_foreground/0,
         device_os_version/0,
         device_model/0,
         %% Test harness — native UI inspection and interaction
         ui_tree/0,
         ui_view_tree/0,
         ui_debug/0,
         screen_info/0,
         tap/1,
         ax_action/2,
         ax_action_at_xy/3,
         tap_xy/2,
         type_text/1,
         delete_backward/0,
         key_press/1,
         clear_text/0,
         long_press_xy/3,
         swipe_xy/4]).

-nifs([platform/0,
       log/1, log/2,
       set_transition/1,
       set_root/1,
       register_tap/1,
       clear_taps/0,
       exit_app/0,
       safe_area/0,
       haptic/1,
       clipboard_put/1,
       clipboard_get/0,
       share_text/1,
       request_permission/1,
       biometric_authenticate/1,
       location_get_once/0,
       location_start/1,
       location_stop/0,
       camera_capture_photo/1,
       camera_capture_video/1,
       camera_start_preview/1,
       camera_stop_preview/0,
       photos_pick/2,
       files_pick/1,
       audio_start_recording/1,
       audio_stop_recording/0,
       audio_play/2,
       audio_stop_playback/0,
       audio_set_volume/1,
       motion_start/2,
       motion_stop/0,
       scanner_scan/1,
       notify_schedule/1,
       notify_cancel/1,
       notify_register_push/0,
       take_launch_notification/0,
       background_keep_alive/0,
       background_stop/0,
       battery_level/0,
       device_set_dispatcher/1,
       device_battery_state/0,
       device_thermal_state/0,
       device_low_power_mode/0,
       device_foreground/0,
       device_os_version/0,
       device_model/0,
       ui_tree/0,
       ui_view_tree/0,
       ui_debug/0,
       screen_info/0,
       tap/1,
       ax_action/2,
       ax_action_at_xy/3,
       tap_xy/2,
       type_text/1,
       delete_backward/0,
       key_press/1,
       clear_text/0,
       long_press_xy/3,
       swipe_xy/4,
       %% Storage
       storage_dir/1,
       storage_save_to_photo_library/1,
       storage_save_to_media_store/2,
       storage_external_files_dir/1,
       %% Alerts / overlays
       alert_show/3,
       action_sheet_show/2,
       toast_show/2,
       %% WebView
       webview_eval_js/1,
       webview_post_message/1,
       webview_can_go_back/0,
       webview_go_back/0,
       %% Native view components
       register_component/1,
       deregister_component/1]).

-on_load(init/0).

init() -> erlang:load_nif("mob_nif", 0).

platform()                        -> erlang:nif_error(not_loaded).
log(_Msg)                         -> erlang:nif_error(not_loaded).
log(_Level, _Msg)                 -> erlang:nif_error(not_loaded).
set_transition(_Trans)            -> erlang:nif_error(not_loaded).
set_root(_Json)                   -> erlang:nif_error(not_loaded).
register_tap(_Pid)                -> erlang:nif_error(not_loaded).
clear_taps()                      -> erlang:nif_error(not_loaded).
exit_app()                        -> erlang:nif_error(not_loaded).
safe_area()                       -> erlang:nif_error(not_loaded).
haptic(_Type)                     -> erlang:nif_error(not_loaded).
clipboard_put(_Text)              -> erlang:nif_error(not_loaded).
clipboard_get()                   -> erlang:nif_error(not_loaded).
share_text(_Text)                 -> erlang:nif_error(not_loaded).
request_permission(_Cap)          -> erlang:nif_error(not_loaded).
biometric_authenticate(_Reason)   -> erlang:nif_error(not_loaded).
location_get_once()               -> erlang:nif_error(not_loaded).
location_start(_Accuracy)         -> erlang:nif_error(not_loaded).
location_stop()                   -> erlang:nif_error(not_loaded).
camera_capture_photo(_Quality)    -> erlang:nif_error(not_loaded).
camera_capture_video(_MaxDuration)-> erlang:nif_error(not_loaded).
camera_start_preview(_OptsJson)   -> erlang:nif_error(not_loaded).
camera_stop_preview()             -> erlang:nif_error(not_loaded).
photos_pick(_Max, _Types)         -> erlang:nif_error(not_loaded).
files_pick(_MimeTypes)            -> erlang:nif_error(not_loaded).
audio_start_recording(_OptsJson)  -> erlang:nif_error(not_loaded).
audio_stop_recording()            -> erlang:nif_error(not_loaded).
audio_play(_Path, _OptsJson)      -> erlang:nif_error(not_loaded).
audio_stop_playback()             -> erlang:nif_error(not_loaded).
audio_set_volume(_Volume)         -> erlang:nif_error(not_loaded).
motion_start(_Sensors, _Interval) -> erlang:nif_error(not_loaded).
motion_stop()                     -> erlang:nif_error(not_loaded).
scanner_scan(_FormatsJson)        -> erlang:nif_error(not_loaded).
notify_schedule(_OptsJson)        -> erlang:nif_error(not_loaded).
notify_cancel(_Id)                -> erlang:nif_error(not_loaded).
notify_register_push()            -> erlang:nif_error(not_loaded).
take_launch_notification()        -> erlang:nif_error(not_loaded).
background_keep_alive()           -> erlang:nif_error(not_loaded).
background_stop()                 -> erlang:nif_error(not_loaded).
battery_level()                   -> erlang:nif_error(not_loaded).
device_set_dispatcher(_Pid)       -> erlang:nif_error(not_loaded).
device_battery_state()            -> erlang:nif_error(not_loaded).
device_thermal_state()            -> erlang:nif_error(not_loaded).
device_low_power_mode()           -> erlang:nif_error(not_loaded).
device_foreground()               -> erlang:nif_error(not_loaded).
device_os_version()               -> erlang:nif_error(not_loaded).
device_model()                    -> erlang:nif_error(not_loaded).
ui_tree()                         -> erlang:nif_error(not_loaded).
ui_view_tree()                    -> erlang:nif_error(not_loaded).
ui_debug()                        -> erlang:nif_error(not_loaded).
screen_info()                     -> erlang:nif_error(not_loaded).
tap(_Label)                       -> erlang:nif_error(not_loaded).
ax_action(_Match, _Action)        -> erlang:nif_error(not_loaded).
ax_action_at_xy(_X, _Y, _Action)  -> erlang:nif_error(not_loaded).
tap_xy(_X, _Y)                    -> erlang:nif_error(not_loaded).
type_text(_Text)                  -> erlang:nif_error(not_loaded).
delete_backward()                 -> erlang:nif_error(not_loaded).
key_press(_Key)                   -> erlang:nif_error(not_loaded).
clear_text()                      -> erlang:nif_error(not_loaded).
long_press_xy(_X, _Y, _Ms)        -> erlang:nif_error(not_loaded).
swipe_xy(_X1, _Y1, _X2, _Y2)     -> erlang:nif_error(not_loaded).
storage_dir(_Location)                      -> erlang:nif_error(not_loaded).
storage_save_to_photo_library(_Path)        -> erlang:nif_error(not_loaded).
storage_save_to_media_store(_Path, _Type)   -> erlang:nif_error(not_loaded).
storage_external_files_dir(_Type)           -> erlang:nif_error(not_loaded).
alert_show(_Title, _Message, _ButtonsJson)  -> erlang:nif_error(not_loaded).
action_sheet_show(_Title, _ButtonsJson)     -> erlang:nif_error(not_loaded).
toast_show(_Message, _Duration)            -> erlang:nif_error(not_loaded).
webview_eval_js(_Code)                      -> erlang:nif_error(not_loaded).
webview_post_message(_Json)                 -> erlang:nif_error(not_loaded).
webview_can_go_back()                       -> erlang:nif_error(not_loaded).
webview_go_back()                           -> erlang:nif_error(not_loaded).
register_component(_Pid)                    -> erlang:nif_error(not_loaded).
deregister_component(_Handle)              -> erlang:nif_error(not_loaded).
