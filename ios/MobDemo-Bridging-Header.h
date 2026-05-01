// MobDemo-Bridging-Header.h — Exposes Mob ObjC types to Swift.
// Passed to swiftc via -import-objc-header.

#import "MobNode.h"

// Called from MobHostingController to signal a back gesture to the BEAM.
// Implemented in mob_nif.m; looks up :mob_screen and sends {:mob, :back}.
void mob_handle_back(void);

// Called from MobRootView.swift WebView delegate when JS sends a message or a URL is blocked.
// Implemented in mob_nif.m; looks up :mob_screen and sends the appropriate tuple.
void mob_deliver_webview_message(const char* json_utf8);
void mob_deliver_webview_blocked(const char* url_utf8);

// Called from MobNativeViewRegistry.send closure when a native view fires an event.
// Implemented in mob_nif.m; looks up the component pid by handle and delivers
// {:component_event, event, payload_json} to it.
void mob_send_component_event(int handle, const char* event, const char* payload_json);

// Called from MobRootView.swift's .onChange(of: colorScheme) modifier when
// the OS appearance toggles (light/dark). Dispatches to Mob.Device subscribers.
// `scheme` is "light" or "dark".
void mob_notify_color_scheme(const char* scheme);
