// driver_tab_ios.c — Static NIF table with mob_nif added.
// Link BEFORE libbeam.a to override the built-in driver_tab.
// Mirrors driver_tab_android.c for iOS.

#include <stddef.h>

typedef struct { void* de; int flags; } ErtsStaticDriver;
#define THE_NON_VALUE ((unsigned long)0)
typedef struct {
    void* (*nif_init)(void);
    int   is_builtin;
    unsigned long nif_mod;
    void* entry;
} ErtsStaticNif;

typedef struct { void* de; int flags; } ErlDrvEntryStub;
extern ErlDrvEntryStub inet_driver_entry;
extern ErlDrvEntryStub ram_file_driver_entry;

ErtsStaticDriver driver_tab[] = {
    {&inet_driver_entry, 0},
    {&ram_file_driver_entry, 0},
    {NULL, 0}
};

void erts_init_static_drivers(void) {}

void *prim_tty_nif_init(void);
void *erl_tracer_nif_init(void);
void *prim_buffer_nif_init(void);
void *prim_file_nif_init(void);
void *zlib_nif_init(void);
void *zstd_nif_init(void);
void *prim_socket_nif_init(void);
void *prim_net_nif_init(void);
void *asn1rt_nif_nif_init(void);

// crypto.c's ERL_NIF_INIT(crypto, ...) generates: crypto_nif_init.
// Built into the app binary via crypto.a + libcrypto.a (OpenSSL).
// Same pattern as Android — see driver_tab_android.c for the rationale
// (Android RTLD_LOCAL hides parent's enif_* symbols from dlopen'd
// children; iOS App Store likewise rejects dynamic NIFs in the bundle).
void *crypto_nif_init(void);

// mob_nif.m's ERL_NIF_INIT(mob_nif,...) with -DSTATIC_ERLANG_NIF
// generates function name: mob_nif_nif_init
void *mob_nif_nif_init(void);

// exqlite sqlite3_nif is linked statically on device (pass -DMOB_STATIC_SQLITE_NIF
// when compiling this file in device builds). On simulator it loads dynamically
// as a .so and must NOT appear in the static table.
#ifdef MOB_STATIC_SQLITE_NIF
void *sqlite3_nif_nif_init(void);
#endif

ErtsStaticNif erts_static_nif_tab[] = {
    {prim_tty_nif_init,     0, THE_NON_VALUE, NULL},
    {erl_tracer_nif_init,   0, THE_NON_VALUE, NULL},
    {prim_buffer_nif_init,  0, THE_NON_VALUE, NULL},
    {prim_file_nif_init,    0, THE_NON_VALUE, NULL},
    {zlib_nif_init,         0, THE_NON_VALUE, NULL},
    {zstd_nif_init,         0, THE_NON_VALUE, NULL},
    {prim_socket_nif_init,  0, THE_NON_VALUE, NULL},
    {prim_net_nif_init,     0, THE_NON_VALUE, NULL},
    {asn1rt_nif_nif_init,   1, THE_NON_VALUE, NULL},
    {crypto_nif_init,       1, THE_NON_VALUE, NULL},
    {mob_nif_nif_init,      0, THE_NON_VALUE, NULL},
#ifdef MOB_STATIC_SQLITE_NIF
    {sqlite3_nif_nif_init,  0, THE_NON_VALUE, NULL},
#endif
    {NULL,                  0, THE_NON_VALUE, NULL}
};
