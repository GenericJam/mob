// mob_beam.h — Public API for mob's BEAM launcher on iOS.
// Include this in your app's beam_main.m stub.

#ifndef MOB_BEAM_H
#define MOB_BEAM_H

#include <stdbool.h>

// Call from application:didFinishLaunchingWithOptions: (main thread), before it
// returns. Installs mob's notification-center delegate (unless the app set its
// own), which iOS requires before launch finishes to hand over the notification
// tap that launched the app.
void mob_init_ui(void);

// What mob_init_ui calls for the delegate. Exposed for a host that boots mob
// without mob_init_ui; same before-launch-finishes requirement.
void mob_install_notification_delegate(void);

// Call mob_start_beam on a background thread — erl_start never returns.
// app_module: Erlang module name, e.g. "mob_demo"
void mob_start_beam(const char *app_module);

// Update the startup status shown on screen while BEAM is initialising.
// mob_set_startup_error stalls the screen with an error message (does not crash).
// Both are safe to call from any thread.
void mob_set_startup_phase(const char *phase);
void mob_set_startup_error(const char *error);

// Call from AppDelegate didRegisterForRemoteNotificationsWithDeviceToken
// to forward the APNs device token to the BEAM as {:push_token, :ios, hex_string}.
// Convert the raw NSData to a hex string before calling.
void mob_send_push_token(const char *hex_token);

// Hand mob a notification as the Mob.Notification JSON envelope
// ({"id","title","body","source","presentation","action","data"}; a missing
// "presentation" means "tap"). Delivered as handle_info({:notification, map})
// to the screen showing, after the root screen has mounted if the BEAM is not
// up yet. Not needed for notifications posted through UNUserNotificationCenter:
// mob's delegate delivers those, including the tap that launched the app, so
// calling this for that tap as well would deliver it twice. Passing NULL clears
// any stored, not yet delivered notifications.
void mob_set_launch_notification_json(const char *json);

// Call from AppDelegate application:openURL:options: (or scene equivalent) when
// another app hands us a file to open — e.g. a `.livemd` emailed to the user and
// tapped, routed here because Info.plist declares the document type. Pass the
// NSURL's `path` (or absoluteString). Mob copies the file into tmp and delivers
// it to the BEAM: at the root screen's mount via Mob.Files.take_opened_document/0
// (cold launch), and as {:files, :opened, item} to that screen if the app was
// already running (warm).
void mob_handle_opened_url(const char *url_cstr);

// Call from SceneDelegate scene:willConnectToSession: after the window is
// created. Tells the BEAM the window now exists so a screen that painted
// earlier — a background or prewarmed launch — can re-read its safe-area
// insets and repaint. Safe to call when no BEAM is running: it is a no-op.
void mob_notify_window_connected(void);
// True once erts is initialised (mob_nif's load callback ran); the notifiers
// above are no-ops before that.
bool mob_runtime_up(void);
void mob_runtime_down(void);

#endif // MOB_BEAM_H
