// mob_beam.h — Public API for mob's BEAM launcher on iOS.
// Include this in your app's beam_main.m stub.

#ifndef MOB_BEAM_H
#define MOB_BEAM_H

// Call from application:didFinishLaunchingWithOptions: (main thread).
// No-op in the SwiftUI build; kept for API compatibility.
void mob_init_ui(void);

// Call mob_start_beam on a background thread — erl_start never returns.
// app_module: Erlang module name, e.g. "mob_demo"
void mob_start_beam(const char* app_module);

// Update the startup status shown on screen while BEAM is initialising.
// mob_set_startup_error stalls the screen with an error message (does not crash).
// Both are safe to call from any thread.
void mob_set_startup_phase(const char* phase);
void mob_set_startup_error(const char* error);

// Call from AppDelegate didRegisterForRemoteNotificationsWithDeviceToken
// to forward the APNs device token to the BEAM as {:push_token, :ios, hex_string}.
// Convert the raw NSData to a hex string before calling.
void mob_send_push_token(const char* hex_token);

// Store a notification JSON payload that launched the app from a killed state.
// Call from application:didFinishLaunchingWithOptions: or scene:willConnectTo:
// when a remote/local notification is the launch cause. The BEAM will deliver
// it via handle_info({:notification, ...}) after the root screen is mounted.
void mob_set_launch_notification_json(const char* json);

#endif // MOB_BEAM_H
