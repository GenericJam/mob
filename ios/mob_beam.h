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

#endif // MOB_BEAM_H
