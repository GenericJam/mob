// MobDemo-Bridging-Header.h — Exposes Mob ObjC types to Swift.
// Passed to swiftc via -import-objc-header.

#import <stdint.h>

#import "MobNode.h"

// Called from MobHostingController to signal a back gesture to the BEAM.
// Implemented in mob_nif.m; looks up :mob_screen and sends {:mob, :back}.
void mob_handle_back(void);

// Called from MobRootView.swift WebView delegate when JS sends a message or a URL is blocked.
// Implemented in mob_nif.m; looks up :mob_screen and sends the appropriate tuple.
void mob_deliver_webview_message(const char *json_utf8);
void mob_deliver_webview_blocked(const char *url_utf8);

// Called from MobNativeViewRegistry.send closure when a native view fires an event.
// Implemented in mob_nif.m; looks up the component pid by handle and delivers
// {:component_event, event, payload_json} to it.
void mob_send_component_event(int handle, const char *event, const char *payload_json);

// Called from MobRootView.swift's .onChange(of: colorScheme) modifier when
// the OS appearance toggles (light/dark). Dispatches to Mob.Device subscribers.
// `scheme` is "light" or "dark".
void mob_notify_color_scheme(const char *scheme);

// Called from MobFrameTracker (SwiftUI) as a tagged element lays out, recording
// its on-screen frame (logical points) keyed by the element's :id. Read back via
// the element_frames NIF so an agent can locate/drive elements without a
// screenshot. Implemented in mob_nif.m.
//
// `generation` is the value mob_frame_generation() returned when the caller
// appeared; writes stamped with a superseded generation are refused, so a
// screen animating out of a nav transition stops reporting itself. Pass 0 if
// it hasn't been captured yet and the write will be accepted.
//
// Returns a monotonic write sequence number the caller keeps so it can pair
// this write with mob_unregister_frame below; 0 means the write was rejected
// (unknown id, a superseded generation, or an id absent from the tree BEAM
// most recently sent).
uint64_t mob_register_frame(const char *id, uint64_t generation, double x, double y, double w,
                            double h);

// Current frame generation — bumped on every identity-destroying navigation.
// MobFrameTracker captures this on appear and stamps its writes with it.
uint64_t mob_frame_generation(void);

// Called from MobFrameTracker's .onDisappear when a tracked element stops being
// laid out — a lazy-list row scrolled out of range, an inactive tab's subtree —
// while its :id is still present in the BEAM tree, so nif_set_root's purge
// never drops it. `seq` is the value the matching mob_register_frame returned:
// the entry is removed only if that write is still the current one, so an
// outgoing screen can't delete an entry an incoming screen just claimed under
// the same :id.
void mob_unregister_frame(const char *id, uint64_t seq);

// Called from MobRootView.swift's resolvedFont to get the ordered fallback
// font names from the last Mob.Theme.set/1 (nif_set_theme in mob_nif.m
// stores it). Empty (never nil) when no theme has set font_fallback.
NSArray<NSString *> *mob_font_fallback(void);
