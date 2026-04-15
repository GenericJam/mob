// mob_beam.h — Public API for mob's BEAM launcher and UI initialisation.
// Include this in your app's beam_jni.c stub.

#ifndef MOB_BEAM_H
#define MOB_BEAM_H

#include <jni.h>

// Call from JNI_OnLoad (main thread).
// bridge_class: e.g. "com/myapp/MobBridge"
void mob_ui_cache_class(JNIEnv* env, const char* bridge_class);

// Send a tap event to the BEAM process registered for handle.
// Called from the app's Java_..._MobBridge_nativeSendTap JNI stub.
void mob_send_tap(int handle);

// Send a {:change, tag, value} event.  Called from the app's
// Java_..._MobBridge_nativeSendChange* JNI stubs.
void mob_send_change_str(int handle, const char* utf8);
void mob_send_change_bool(int handle, int bool_val);   // 0 = false, 1 = true
void mob_send_change_float(int handle, double value);

// Send {:focus, tag}, {:blur, tag}, {:submit, tag} events.
void mob_send_focus(int handle);
void mob_send_blur(int handle);
void mob_send_submit(int handle);

// Signal a system back gesture to the BEAM screen process.
// The BEAM pops the nav stack or calls exit_app if at root.
void mob_handle_back(void);

// Call from nativeSetActivity.
void mob_init_bridge(JNIEnv* env, jobject activity);

// Call from nativeStartBeam.
// app_module: Erlang module name, e.g. "mob_demo"
void mob_start_beam(const char* app_module);

// Global JVM pointer — defined in mob_beam.c, extern'd for mob_nif.c.
extern JavaVM* g_jvm;
extern jobject g_activity;

#endif // MOB_BEAM_H
