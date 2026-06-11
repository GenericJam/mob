%% mob_nif.erl — Erlang NIF stub module.
%% ERL_NIF_INIT in mob_nif.c / mob_nif.m registers functions under this module name.
-module(mob_nif).
-export([
    platform/0,
    color_scheme/0,
    log/1, log/2,
    set_transition/1,
    set_root/1,
    set_theme/1,
    register_tap/1,
    clear_taps/0,
    exit_app/0,
    safe_area/0,
    %% Device utilities (no permission required)
    haptic/1,
    clipboard_put/1,
    clipboard_get/0,
    share_text/1,
    open_url/1,
    %% Permissions
    request_permission/1,
    %% Biometric
    %% Photo library
    %% File picker
    files_pick/1,
    %% Audio recording
    audio_start_recording/1,
    audio_stop_recording/0,
    %% Audio playback
    audio_play/2,
    audio_play_at/3,
    audio_stop_playback/0,
    audio_set_volume/1,
    %% Text-to-speech (no permission required)
    tts_speak/2,
    tts_stop/0,
    %% Motion sensors
    motion_start/2,
    motion_stop/0,
    %% QR / barcode scanner
    scanner_scan/1,
    %% Notifications
    take_launch_notification/0,
    take_opened_document/0,
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
    swipe_xy/4,
    %% Test harness — in-process visual capture and scroll control
    %% (remote-driving: agent gets pixels + deterministic scroll over dist,
    %% no adb/xcrun). See Mob.Test.screenshot/2, scroll_info/2, scroll_to/3.
    screenshot/3,
    scroll_info/1,
    scroll_to/3,
    element_frames/0,
    %% Peripheral.VendorUsb (Android USB host; iOS returns :unsupported)
    vendor_usb_list_devices/1,
    vendor_usb_request_permission/1,
    vendor_usb_open/1,
    vendor_usb_bulk_write/3,
    vendor_usb_start_reading/2,
    vendor_usb_stop_reading/1,
    vendor_usb_close/1,
    %% Bluetooth Classic (Android; iOS returns :unsupported)
    bt_list_paired/0,
    bt_start_discovery/0,
    bt_cancel_discovery/0,
    bt_pair/1,
    bt_unpair/1,
    bt_disconnect/1,
    bt_hfp_connect/1,
    bt_hfp_subscribe_vendor_at/2,
    bt_hfp_send_vendor_at/3,
    bt_hfp_start_sco/1,
    bt_hfp_stop_sco/1,
    bt_hfp_send_audio/2,
    bt_spp_connect/1,
    bt_spp_write/2,
    bt_hid_connect/1,
    bt_hid_subscribe_raw/1,
    %% DNS — see Mob.DNS and guides/dns_on_ios.md
    resolve_ipv4/1
]).

-nifs([
    platform/0,
    color_scheme/0,
    log/1,
    log/2,
    set_transition/1,
    set_root/1,
    set_theme/1,
    register_tap/1,
    clear_taps/0,
    exit_app/0,
    safe_area/0,
    haptic/1,
    clipboard_put/1,
    clipboard_get/0,
    share_text/1,
    open_url/1,
    request_permission/1,
    files_pick/1,
    audio_start_recording/1,
    audio_stop_recording/0,
    audio_play/2,
    audio_play_at/3,
    audio_stop_playback/0,
    audio_set_volume/1,
    tts_speak/2,
    tts_stop/0,
    motion_start/2,
    motion_stop/0,
    scanner_scan/1,
    take_launch_notification/0,
    take_opened_document/0,
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
    screenshot/3,
    scroll_info/1,
    scroll_to/3,
    element_frames/0,
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
    %% Peripheral.VendorUsb
    vendor_usb_list_devices/1,
    vendor_usb_request_permission/1,
    vendor_usb_open/1,
    vendor_usb_bulk_write/3,
    vendor_usb_start_reading/2,
    vendor_usb_stop_reading/1,
    vendor_usb_close/1,
    %% Bluetooth Classic
    bt_list_paired/0,
    bt_start_discovery/0,
    bt_cancel_discovery/0,
    bt_pair/1,
    bt_unpair/1,
    bt_disconnect/1,
    bt_hfp_connect/1,
    bt_hfp_subscribe_vendor_at/2,
    bt_hfp_send_vendor_at/3,
    bt_hfp_start_sco/1,
    bt_hfp_stop_sco/1,
    bt_hfp_send_audio/2,
    bt_spp_connect/1,
    bt_spp_write/2,
    bt_hid_connect/1,
    bt_hid_subscribe_raw/1,
    %% DNS — in-process getaddrinfo so iOS apps bypass BEAM's
    %% broken inet_gethost path. See `Mob.DNS` for the Elixir
    %% wrapper and `guides/dns_on_ios.md` for the why.
    resolve_ipv4/1
]).

-on_load(init/0).

init() -> erlang:load_nif("mob_nif", 0).

platform() -> erlang:nif_error(not_loaded).
color_scheme() -> erlang:nif_error(not_loaded).
log(_Msg) -> erlang:nif_error(not_loaded).
log(_Level, _Msg) -> erlang:nif_error(not_loaded).
set_transition(_Trans) -> erlang:nif_error(not_loaded).
set_root(_Json) -> erlang:nif_error(not_loaded).

%% set_theme(JsonBinary) — push resolved theme palette to the native side.
%% Lets Compose's MaterialTheme / SwiftUI environment follow runtime
%% Mob.Theme.set/1 calls instead of being baked into the host project's
%% MainActivity / app entry point. Called from Mob.Theme.set/1; the host
%% bridge consumes via MobBridge.setTheme(json) on Android (no-op on iOS,
%% which doesn't currently route Mob.Theme through native chrome).
set_theme(_Json) -> erlang:nif_error(not_loaded).
register_tap(_Pid) -> erlang:nif_error(not_loaded).
clear_taps() -> erlang:nif_error(not_loaded).
exit_app() -> erlang:nif_error(not_loaded).
safe_area() -> erlang:nif_error(not_loaded).
haptic(_Type) -> erlang:nif_error(not_loaded).
clipboard_put(_Text) -> erlang:nif_error(not_loaded).
clipboard_get() -> erlang:nif_error(not_loaded).
share_text(_Text) -> erlang:nif_error(not_loaded).
open_url(_Url) -> erlang:nif_error(not_loaded).
request_permission(_Cap) -> erlang:nif_error(not_loaded).
files_pick(_MimeTypes) -> erlang:nif_error(not_loaded).
audio_start_recording(_OptsJson) -> erlang:nif_error(not_loaded).
audio_stop_recording() -> erlang:nif_error(not_loaded).
audio_play(_Path, _OptsJson) -> erlang:nif_error(not_loaded).
audio_play_at(_Path, _OptsJson, _AtWallMs) -> erlang:nif_error(not_loaded).
audio_stop_playback() -> erlang:nif_error(not_loaded).
audio_set_volume(_Volume) -> erlang:nif_error(not_loaded).
tts_speak(_Text, _OptsJson) -> erlang:nif_error(not_loaded).
tts_stop() -> erlang:nif_error(not_loaded).
motion_start(_Sensors, _Interval) -> erlang:nif_error(not_loaded).
motion_stop() -> erlang:nif_error(not_loaded).
scanner_scan(_FormatsJson) -> erlang:nif_error(not_loaded).
take_launch_notification() -> erlang:nif_error(not_loaded).
take_opened_document() -> erlang:nif_error(not_loaded).
background_keep_alive() -> erlang:nif_error(not_loaded).
background_stop() -> erlang:nif_error(not_loaded).
battery_level() -> erlang:nif_error(not_loaded).
device_set_dispatcher(_Pid) -> erlang:nif_error(not_loaded).
device_battery_state() -> erlang:nif_error(not_loaded).
device_thermal_state() -> erlang:nif_error(not_loaded).
device_low_power_mode() -> erlang:nif_error(not_loaded).
device_foreground() -> erlang:nif_error(not_loaded).
device_os_version() -> erlang:nif_error(not_loaded).
device_model() -> erlang:nif_error(not_loaded).
ui_tree() -> erlang:nif_error(not_loaded).
ui_view_tree() -> erlang:nif_error(not_loaded).
ui_debug() -> erlang:nif_error(not_loaded).
screen_info() -> erlang:nif_error(not_loaded).
tap(_Label) -> erlang:nif_error(not_loaded).
ax_action(_Match, _Action) -> erlang:nif_error(not_loaded).
ax_action_at_xy(_X, _Y, _Action) -> erlang:nif_error(not_loaded).
tap_xy(_X, _Y) -> erlang:nif_error(not_loaded).
type_text(_Text) -> erlang:nif_error(not_loaded).
delete_backward() -> erlang:nif_error(not_loaded).
key_press(_Key) -> erlang:nif_error(not_loaded).
clear_text() -> erlang:nif_error(not_loaded).
long_press_xy(_X, _Y, _Ms) -> erlang:nif_error(not_loaded).
swipe_xy(_X1, _Y1, _X2, _Y2) -> erlang:nif_error(not_loaded).
%% In-process visual capture + scroll control (see Mob.Test).
%% screenshot(Format, Quality, Scale) -> Binary (PNG/JPEG bytes) | {error, Reason}
%%   Format :: png | jpeg, Quality :: 0..100 (jpeg), Scale :: float
%% scroll_info(Id) -> #{offset, content, viewport, max_offset, kind} | {error, Reason}
%% scroll_to(Id, X, Y) -> ok | {error, Reason}
screenshot(_Format, _Quality, _Scale) -> erlang:nif_error(not_loaded).
scroll_info(_Id) -> erlang:nif_error(not_loaded).
scroll_to(_Id, _X, _Y) -> erlang:nif_error(not_loaded).
%% element_frames() -> JSON binary {"id":[x,y,w,h],...} of on-screen frames for
%% every rendered node that carries an :id (logical points iOS / dp Android).
%% Lets an agent locate + drive elements by id without a screenshot.
element_frames() -> erlang:nif_error(not_loaded).
storage_dir(_Location) -> erlang:nif_error(not_loaded).
storage_save_to_photo_library(_Path) -> erlang:nif_error(not_loaded).
storage_save_to_media_store(_Path, _Type) -> erlang:nif_error(not_loaded).
storage_external_files_dir(_Type) -> erlang:nif_error(not_loaded).
alert_show(_Title, _Message, _ButtonsJson) -> erlang:nif_error(not_loaded).
action_sheet_show(_Title, _ButtonsJson) -> erlang:nif_error(not_loaded).
toast_show(_Message, _Duration) -> erlang:nif_error(not_loaded).
webview_eval_js(_Code) -> erlang:nif_error(not_loaded).
webview_post_message(_Json) -> erlang:nif_error(not_loaded).
webview_can_go_back() -> erlang:nif_error(not_loaded).
webview_go_back() -> erlang:nif_error(not_loaded).
register_component(_Pid) -> erlang:nif_error(not_loaded).
deregister_component(_Handle) -> erlang:nif_error(not_loaded).
%% Peripheral.VendorUsb
vendor_usb_list_devices(_FilterJson) -> erlang:nif_error(not_loaded).
vendor_usb_request_permission(_Ref) -> erlang:nif_error(not_loaded).
vendor_usb_open(_OptsJson) -> erlang:nif_error(not_loaded).
vendor_usb_bulk_write(_Session, _Bytes, _TimeoutMs) -> erlang:nif_error(not_loaded).
vendor_usb_start_reading(_Session, _ChunkBytes) -> erlang:nif_error(not_loaded).
vendor_usb_stop_reading(_Session) -> erlang:nif_error(not_loaded).
vendor_usb_close(_Session) -> erlang:nif_error(not_loaded).
%% Bluetooth Classic
bt_list_paired() -> erlang:nif_error(not_loaded).
bt_start_discovery() -> erlang:nif_error(not_loaded).
bt_cancel_discovery() -> erlang:nif_error(not_loaded).
bt_pair(_DeviceAndPinJson) -> erlang:nif_error(not_loaded).
bt_unpair(_DeviceJson) -> erlang:nif_error(not_loaded).
bt_disconnect(_Session) -> erlang:nif_error(not_loaded).
bt_hfp_connect(_DeviceJson) -> erlang:nif_error(not_loaded).
bt_hfp_subscribe_vendor_at(_Session, _CompanyIdsJson) -> erlang:nif_error(not_loaded).
bt_hfp_send_vendor_at(_Session, _Cmd, _Args) -> erlang:nif_error(not_loaded).
bt_hfp_start_sco(_Session) -> erlang:nif_error(not_loaded).
bt_hfp_stop_sco(_Session) -> erlang:nif_error(not_loaded).
bt_hfp_send_audio(_Session, _Pcm) -> erlang:nif_error(not_loaded).
bt_spp_connect(_DeviceJson) -> erlang:nif_error(not_loaded).
bt_spp_write(_Session, _Bytes) -> erlang:nif_error(not_loaded).
bt_hid_connect(_DeviceJson) -> erlang:nif_error(not_loaded).
bt_hid_subscribe_raw(_Session) -> erlang:nif_error(not_loaded).
resolve_ipv4(_Host) -> erlang:nif_error(not_loaded).
