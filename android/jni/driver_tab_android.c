// driver_tab_android.c — Reference snapshot of the static NIF table.
//
// As of mob 0.5.18 + mob_dev 0.4.x, the source of truth for an app's static
// NIF table lives in the app's mob.exs `:static_nifs` config and is generated
// to priv/generated/driver_tab_android.c via `mix mob.regen_driver_tab`. This
// file remains as a fallback that build templates use when the generated file
// is absent (i.e. the project hasn't been migrated yet).
//
// Keep this file in sync with `MobDev.StaticNifs.default_nifs/0` so the
// fallback matches the generator's default output.
//
// Link BEFORE libbeam.a to override the built-in driver_tab.

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

// crypto.c's ERL_NIF_INIT(crypto,...) generates: crypto_nif_init.
// Built into libpigeon.so via crypto.a + libcrypto.a (OpenSSL).
// Without this entry, the BEAM falls through to dlopen("crypto.so")
// which fails because Android's RTLD_LOCAL hides libpigeon.so's
// enif_* symbols from the dlopen'd library. With it, the BEAM
// resolves crypto via dlsym(RTLD_DEFAULT) and load_nif uses the
// static path — no dlopen, real OpenSSL.
void *crypto_nif_init(void);

// mob_nif.c's ERL_NIF_INIT(mob_nif,...) generates: mob_nif_nif_init
void *mob_nif_nif_init(void);

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
    {NULL,                  0, THE_NON_VALUE, NULL}
};
