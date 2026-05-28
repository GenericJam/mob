//! mob_zig.zig — Hand-declared JNI/Android/libc bindings for Mob's Zig code.
//!
//! Phase 6b of the build-system migration translates mob's Android C source
//! (mob_beam.c, mob_nif.c) to Zig. Zig 0.17-dev's `@cImport` builtin was
//! removed and `zig translate-c` hangs on the Android NDK's `jni.h` (deep
//! recursive include tree). Hand-declaring the FFI surface sidesteps both:
//!
//!   * **Stable**: JNI ABI hasn't materially changed since Java 1.1 (1997).
//!     Android log + libc surface used here is similarly stable.
//!   * **Minimal**: declares only what Mob's Zig source actually uses.
//!     ~250 lines beats a thousand-line auto-generated translation.
//!   * **Auditable**: a reviewer can read the whole binding in one sitting.
//!   * **Future-proof**: doesn't depend on Zig version's @cImport behavior.
//!
//! The hand-declared layouts mirror the C headers byte-for-byte (verified
//! against AOSP's `frameworks/native/include/jni.h` and Android NDK's
//! `android/log.h`, `dlfcn.h`, etc.).

const std = @import("std");

// ── Android log ────────────────────────────────────────────────────────────

pub const ANDROID_LOG_VERBOSE: c_int = 2;
pub const ANDROID_LOG_DEBUG: c_int = 3;
pub const ANDROID_LOG_INFO: c_int = 4;
pub const ANDROID_LOG_WARN: c_int = 5;
pub const ANDROID_LOG_ERROR: c_int = 6;

pub extern fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
pub extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;

/// Format a message with std.fmt and write it via __android_log_write.
/// Truncates safely on oversize input (Android log already truncates at
/// ~4 KB anyway).
pub fn logWrite(prio: c_int, comptime tag: [*:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..(buf.len - 1)];
    // bufPrint doesn't NUL-terminate; we need NUL for __android_log_write.
    const end = @min(slice.len, buf.len - 1);
    buf[end] = 0;
    _ = __android_log_write(prio, tag, buf[0..end :0]);
}

// ── POSIX / libc ───────────────────────────────────────────────────────────

pub const STDOUT_FILENO: c_int = 1;
pub const STDERR_FILENO: c_int = 2;

pub extern fn pipe(fds: *[2]c_int) c_int;
pub extern fn dup2(oldfd: c_int, newfd: c_int) c_int;
pub extern fn close(fd: c_int) c_int;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
pub extern fn setvbuf(stream: *FILE, buf: ?[*]u8, mode: c_int, size: usize) c_int;
pub extern fn fopen(pathname: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
pub extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
pub extern fn fclose(stream: *FILE) c_int;
/// bionic's errno getter. The C `errno` macro expands to `(*__errno())`.
/// Symbol name matches the linker name in libc.so (`__errno`, not
/// `__errno_location` — that's the glibc spelling).
pub extern fn __errno() *c_int;
pub extern fn strerror(errnum: c_int) [*:0]const u8;
pub extern fn strncmp(s1: [*]const u8, s2: [*]const u8, n: usize) c_int;
pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern fn mkdir(pathname: [*:0]const u8, mode: u32) c_int;
pub extern fn unlink(pathname: [*:0]const u8) c_int;
pub extern fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
pub extern fn stat(pathname: [*:0]const u8, statbuf: *Stat) c_int;
pub extern fn opendir(name: [*:0]const u8) ?*DIR;
pub extern fn readdir(dirp: *DIR) ?*Dirent;
pub extern fn closedir(dirp: *DIR) c_int;
pub extern fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
pub extern fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) c_int;

/// dladdr — POSIX/glibc/Bionic extension. Given an address, fills in
/// information about the shared object containing it. Used by the
/// BEAM launcher to discover libpigeon.so's absolute path so it can
/// be passed to rustler (and any other consumer) via env var.
pub const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};

pub extern fn dladdr(addr: *const anyopaque, info: *DlInfo) c_int;

/// POSIX clock identifiers. We only use CLOCK_MONOTONIC for throttle
/// timestamps in the gesture/scroll/drag/pinch sender path — it ticks
/// forward at a constant rate regardless of wall-clock NTP adjustments.
pub const CLOCK_MONOTONIC: c_int = 1;
pub extern fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

/// Monotonic nanoseconds since boot. Wrapper that hides the timespec
/// dance. Used by the throttle path in the senders.
pub fn nowNs() i64 {
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}

// libc allocator. We use `std.heap.c_allocator` in only one spot (test
// harness NIFs that copy a binary into a NUL-terminated buffer for
// NewStringUTF), and Zig 0.17 refuses to compile `std.heap.c_allocator`
// without `linkLibC()` on the module. Production builds link libc via
// the NDK clang link step anyway, so calling malloc/free directly is
// equivalent and skips the link-time guard.
pub extern fn malloc(size: usize) ?*anyopaque;
pub extern fn free(ptr: ?*anyopaque) void;
pub extern fn strlen(s: [*:0]const u8) usize;
pub extern fn strdup(s: [*:0]const u8) ?[*:0]u8;

pub const _IONBF: c_int = 2;

pub const FILE = opaque {};

/// bionic exposes `stdout` and `stderr` as `extern FILE*` symbols (NDK 23+,
/// API ≥ 21). We use them only to call `setvbuf(stdout, NULL, _IONBF, 0)`
/// after redirecting fd 1/2 to a pipe — the libc-side FILE objects retain
/// their own buffer until told otherwise.
pub extern var stdout: *FILE;
pub extern var stderr: *FILE;

/// Opaque DIR for opendir/readdir/closedir.
pub const DIR = opaque {};

/// Android bionic dirent layout (sufficient for us — only need d_name).
/// AOSP source: bionic/libc/include/dirent.h.
pub const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

pub const Stat = extern struct {
    // Layout we don't fully care about — we only call stat() for existence
    // check. Opaque-sized buffer is safer than getting field offsets wrong.
    _opaque: [256]u8,
};

pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub extern fn pthread_create(
    thread: *PthreadT,
    attr: ?*const anyopaque,
    start_routine: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    arg: ?*anyopaque,
) c_int;

pub extern fn pthread_detach(thread: PthreadT) c_int;

pub const PthreadT = usize; // Android: pthread_t is a long unsigned int

// ── dlfcn ──────────────────────────────────────────────────────────────────

pub const RTLD_NOW: c_int = 2;
pub const RTLD_GLOBAL: c_int = 0x00100;

pub extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
pub extern fn dlerror() ?[*:0]const u8;

// ── netdb (in-process DNS) ─────────────────────────────────────────────────
// Bindings for Bionic's getaddrinfo so a NIF can resolve hostnames inside
// the BEAM's process. BEAM's default DNS path forks the `inet_gethost` port
// program and that path returns NXDOMAIN on physical Android devices for
// reasons we haven't fully pinned down (libnetd_client routing through netd
// behaves differently for execve'd children of the app — works on emulator,
// fails on phones we've tested). Calling getaddrinfo in-process from the
// app's UID and address space sidesteps the issue: it's the same code path
// the app's own HTTP stack uses when it succeeds.
//
// Layout mirrors Bionic's `bionic/libc/include/netdb.h` exactly. Note that
// Bionic's `struct addrinfo` orders `ai_canonname` *before* `ai_addr`, which
// is the historical BSD layout — glibc swaps them. Verified against AOSP
// `bionic/libc/include/netdb.h` (NDK r25+).

pub const AF_INET: c_int = 2;
pub const SOCK_STREAM: c_int = 1;

/// `getaddrinfo` EAI_* error codes. Bionic values, which happen to match
/// Darwin BSD for the ones we care about — but we declare them here for
/// clarity at the Zig call site.
pub const EAI_AGAIN: c_int = 2;
pub const EAI_NODATA: c_int = 7;
pub const EAI_NONAME: c_int = 8;

pub const AddrInfo = extern struct {
    ai_flags: c_int,
    ai_family: c_int,
    ai_socktype: c_int,
    ai_protocol: c_int,
    ai_addrlen: u32,
    ai_canonname: ?[*:0]u8,
    ai_addr: ?*SockAddr,
    ai_next: ?*AddrInfo,
};

/// Generic sockaddr used by getaddrinfo's result chain.
pub const SockAddr = extern struct {
    sa_family: u16,
    _padding: [14]u8,
};

/// IPv4 sockaddr layout (sa_family=AF_INET).
pub const SockAddrIn = extern struct {
    sin_family: u16,
    sin_port: u16,
    /// IPv4 address, network byte order.
    sin_addr: u32,
    sin_zero: [8]u8,
};

pub extern fn getaddrinfo(
    node: [*:0]const u8,
    service: ?[*:0]const u8,
    hints: ?*const AddrInfo,
    res: *?*AddrInfo,
) c_int;

pub extern fn freeaddrinfo(res: ?*AddrInfo) void;

// ── JNI ────────────────────────────────────────────────────────────────────
// AOSP source: frameworks/native/include/jni.h. We only declare the vtable
// entries we actually call; future iters can add more as needed.

pub const JNI_VERSION_1_6: c_int = 0x00010006;
pub const JNI_OK: c_int = 0;

pub const JBoolean = u8;
pub const JByte = i8;
pub const JInt = i32;
pub const JLong = i64;
pub const JFloat = f32;
pub const JDouble = f64;
/// `jsize` is a typedef alias for `jint` in jni.h; keep them as distinct
/// names here so the byte-array helpers below read like the JNI signatures
/// they wrap.
pub const JSize = JInt;
pub const JByteArray = JObject;

pub const JObject = ?*anyopaque;
pub const JClass = JObject;
pub const JString = JObject;
pub const JFieldID = ?*anyopaque;
pub const JMethodID = ?*anyopaque;

/// JNIEnv is a pointer-to-pointer-to-JNINativeInterface. C usage:
///   `(*env)->FindClass(env, "..")`
/// Zig usage via our helpers:
///   `jni.findClass(env, "..")`
pub const JNIEnv = *const JNINativeInterface;

/// Vtable inside JNIEnv. Order matters — must match jni.h exactly.
/// We declare only the slots we use, plus reserved padding for the rest.
/// Each `?*const fn(...) callconv(.c) ...` is a function pointer.
pub const JNINativeInterface = extern struct {
    _reserved0: ?*anyopaque,
    _reserved1: ?*anyopaque,
    _reserved2: ?*anyopaque,
    _reserved3: ?*anyopaque,

    // Index 4: GetVersion — unused but in the slot order.
    GetVersion: ?*const fn (env: *JNIEnv) callconv(.c) JInt,

    // 5-8: DefineClass, FindClass, FromReflectedMethod, FromReflectedField
    DefineClass: ?*anyopaque,
    FindClass: ?*const fn (env: *JNIEnv, name: [*:0]const u8) callconv(.c) JClass,
    FromReflectedMethod: ?*anyopaque,
    FromReflectedField: ?*anyopaque,

    // 9-16: reflected/IsAssignableFrom + exceptions block
    ToReflectedMethod: ?*anyopaque,
    GetSuperclass: ?*anyopaque,
    IsAssignableFrom: ?*anyopaque,
    ToReflectedField: ?*anyopaque,
    Throw: ?*anyopaque,
    ThrowNew: ?*anyopaque,
    ExceptionOccurred: ?*anyopaque,
    ExceptionDescribe: ?*anyopaque,

    // 17-22: exception finish, refs
    ExceptionClear: ?*const fn (env: *JNIEnv) callconv(.c) void,
    FatalError: ?*anyopaque,
    PushLocalFrame: ?*anyopaque,
    PopLocalFrame: ?*anyopaque,
    NewGlobalRef: ?*const fn (env: *JNIEnv, obj: JObject) callconv(.c) JObject,
    DeleteGlobalRef: ?*const fn (env: *JNIEnv, gref: JObject) callconv(.c) void,

    // 23-26: local ref slots
    DeleteLocalRef: ?*const fn (env: *JNIEnv, obj: JObject) callconv(.c) void,
    IsSameObject: ?*anyopaque,
    NewLocalRef: ?*anyopaque,
    EnsureLocalCapacity: ?*anyopaque,

    // 27-29: object creation
    AllocObject: ?*anyopaque,
    NewObject: ?*anyopaque,
    NewObjectV: ?*anyopaque,

    // 30-32: object type queries
    NewObjectA: ?*anyopaque,
    GetObjectClass: ?*const fn (env: *JNIEnv, obj: JObject) callconv(.c) JClass,
    IsInstanceOf: ?*anyopaque,

    // 33: GetMethodID
    GetMethodID: ?*const fn (env: *JNIEnv, cls: JClass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) JMethodID,

    // 34-60: many CallXxxMethod variants — we only use CallObjectMethod
    // and CallBooleanMethod by typed signature. Pad as opaque.
    CallObjectMethod: ?*const fn (env: *JNIEnv, obj: JObject, mid: JMethodID, ...) callconv(.c) JObject,
    CallObjectMethodV: ?*anyopaque,
    CallObjectMethodA: ?*anyopaque,
    CallBooleanMethod: ?*const fn (env: *JNIEnv, obj: JObject, mid: JMethodID, ...) callconv(.c) JBoolean,
    CallBooleanMethodV: ?*anyopaque,
    CallBooleanMethodA: ?*anyopaque,
    CallByteMethod: ?*anyopaque,
    CallByteMethodV: ?*anyopaque,
    CallByteMethodA: ?*anyopaque,
    CallCharMethod: ?*anyopaque,
    CallCharMethodV: ?*anyopaque,
    CallCharMethodA: ?*anyopaque,
    CallShortMethod: ?*anyopaque,
    CallShortMethodV: ?*anyopaque,
    CallShortMethodA: ?*anyopaque,
    CallIntMethod: ?*anyopaque,
    CallIntMethodV: ?*anyopaque,
    CallIntMethodA: ?*anyopaque,
    CallLongMethod: ?*anyopaque,
    CallLongMethodV: ?*anyopaque,
    CallLongMethodA: ?*anyopaque,
    CallFloatMethod: ?*anyopaque,
    CallFloatMethodV: ?*anyopaque,
    CallFloatMethodA: ?*anyopaque,
    CallDoubleMethod: ?*anyopaque,
    CallDoubleMethodV: ?*anyopaque,
    CallDoubleMethodA: ?*anyopaque,
    CallVoidMethod: ?*anyopaque,
    CallVoidMethodV: ?*anyopaque,
    CallVoidMethodA: ?*anyopaque,

    // 62-94: nonvirtual call variants + field accessors
    CallNonvirtualObjectMethod: ?*anyopaque,
    CallNonvirtualObjectMethodV: ?*anyopaque,
    CallNonvirtualObjectMethodA: ?*anyopaque,
    CallNonvirtualBooleanMethod: ?*anyopaque,
    CallNonvirtualBooleanMethodV: ?*anyopaque,
    CallNonvirtualBooleanMethodA: ?*anyopaque,
    CallNonvirtualByteMethod: ?*anyopaque,
    CallNonvirtualByteMethodV: ?*anyopaque,
    CallNonvirtualByteMethodA: ?*anyopaque,
    CallNonvirtualCharMethod: ?*anyopaque,
    CallNonvirtualCharMethodV: ?*anyopaque,
    CallNonvirtualCharMethodA: ?*anyopaque,
    CallNonvirtualShortMethod: ?*anyopaque,
    CallNonvirtualShortMethodV: ?*anyopaque,
    CallNonvirtualShortMethodA: ?*anyopaque,
    CallNonvirtualIntMethod: ?*anyopaque,
    CallNonvirtualIntMethodV: ?*anyopaque,
    CallNonvirtualIntMethodA: ?*anyopaque,
    CallNonvirtualLongMethod: ?*anyopaque,
    CallNonvirtualLongMethodV: ?*anyopaque,
    CallNonvirtualLongMethodA: ?*anyopaque,
    CallNonvirtualFloatMethod: ?*anyopaque,
    CallNonvirtualFloatMethodV: ?*anyopaque,
    CallNonvirtualFloatMethodA: ?*anyopaque,
    CallNonvirtualDoubleMethod: ?*anyopaque,
    CallNonvirtualDoubleMethodV: ?*anyopaque,
    CallNonvirtualDoubleMethodA: ?*anyopaque,
    CallNonvirtualVoidMethod: ?*anyopaque,
    CallNonvirtualVoidMethodV: ?*anyopaque,
    CallNonvirtualVoidMethodA: ?*anyopaque,

    // 95: GetFieldID — we use this
    GetFieldID: ?*const fn (env: *JNIEnv, cls: JClass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) JFieldID,

    // 96-104: GetXxxField — we use GetObjectField
    GetObjectField: ?*const fn (env: *JNIEnv, obj: JObject, fid: JFieldID) callconv(.c) JObject,
    GetBooleanField: ?*anyopaque,
    GetByteField: ?*anyopaque,
    GetCharField: ?*anyopaque,
    GetShortField: ?*anyopaque,
    GetIntField: ?*anyopaque,
    GetLongField: ?*anyopaque,
    GetFloatField: ?*anyopaque,
    GetDoubleField: ?*anyopaque,

    // 105-113: SetXxxField + static method id/calls — unused
    SetObjectField: ?*anyopaque,
    SetBooleanField: ?*anyopaque,
    SetByteField: ?*anyopaque,
    SetCharField: ?*anyopaque,
    SetShortField: ?*anyopaque,
    SetIntField: ?*anyopaque,
    SetLongField: ?*anyopaque,
    SetFloatField: ?*anyopaque,
    SetDoubleField: ?*anyopaque,

    // 114-152: GetStaticMethodID + CallStaticXxxMethod variants. Phase 6b
    // iter 3b types the slots mob_nif.zig calls (GetStaticMethodID + the
    // variadic ObjectMethod / BooleanMethod / VoidMethod); the rest stay
    // opaque until a later iter needs them.
    GetStaticMethodID: ?*const fn (env: *JNIEnv, cls: JClass, name: [*:0]const u8, sig: [*:0]const u8) callconv(.c) JMethodID,
    CallStaticObjectMethod: ?*const fn (env: *JNIEnv, cls: JClass, mid: JMethodID, ...) callconv(.c) JObject,
    CallStaticObjectMethodV: ?*anyopaque,
    CallStaticObjectMethodA: ?*anyopaque,
    CallStaticBooleanMethod: ?*const fn (env: *JNIEnv, cls: JClass, mid: JMethodID, ...) callconv(.c) JBoolean,
    CallStaticBooleanMethodV: ?*anyopaque,
    CallStaticBooleanMethodA: ?*anyopaque,
    CallStaticByteMethod: ?*anyopaque,
    CallStaticByteMethodV: ?*anyopaque,
    CallStaticByteMethodA: ?*anyopaque,
    CallStaticCharMethod: ?*anyopaque,
    CallStaticCharMethodV: ?*anyopaque,
    CallStaticCharMethodA: ?*anyopaque,
    CallStaticShortMethod: ?*anyopaque,
    CallStaticShortMethodV: ?*anyopaque,
    CallStaticShortMethodA: ?*anyopaque,
    CallStaticIntMethod: ?*anyopaque,
    CallStaticIntMethodV: ?*anyopaque,
    CallStaticIntMethodA: ?*anyopaque,
    CallStaticLongMethod: ?*anyopaque,
    CallStaticLongMethodV: ?*anyopaque,
    CallStaticLongMethodA: ?*anyopaque,
    CallStaticFloatMethod: ?*anyopaque,
    CallStaticFloatMethodV: ?*anyopaque,
    CallStaticFloatMethodA: ?*anyopaque,
    CallStaticDoubleMethod: ?*anyopaque,
    CallStaticDoubleMethodV: ?*anyopaque,
    CallStaticDoubleMethodA: ?*anyopaque,
    CallStaticVoidMethod: ?*const fn (env: *JNIEnv, cls: JClass, mid: JMethodID, ...) callconv(.c) void,
    CallStaticVoidMethodV: ?*anyopaque,
    CallStaticVoidMethodA: ?*anyopaque,
    GetStaticFieldID: ?*anyopaque,
    GetStaticObjectField: ?*anyopaque,
    GetStaticBooleanField: ?*anyopaque,
    GetStaticByteField: ?*anyopaque,
    GetStaticCharField: ?*anyopaque,
    GetStaticShortField: ?*anyopaque,
    GetStaticIntField: ?*anyopaque,
    GetStaticLongField: ?*anyopaque,
    GetStaticFloatField: ?*anyopaque,
    GetStaticDoubleField: ?*anyopaque,

    // 153-162: SetStaticXxxField — unused
    SetStaticObjectField: ?*anyopaque,
    SetStaticBooleanField: ?*anyopaque,
    SetStaticByteField: ?*anyopaque,
    SetStaticCharField: ?*anyopaque,
    SetStaticShortField: ?*anyopaque,
    SetStaticIntField: ?*anyopaque,
    SetStaticLongField: ?*anyopaque,
    SetStaticFloatField: ?*anyopaque,
    SetStaticDoubleField: ?*anyopaque,

    // 163-168: NewString + GetStringChars — unused but pad for completeness
    NewString: ?*anyopaque,
    GetStringLength: ?*anyopaque,
    GetStringChars: ?*anyopaque,
    ReleaseStringChars: ?*anyopaque,
    NewStringUTF: ?*const fn (env: *JNIEnv, utf: [*:0]const u8) callconv(.c) JString,
    GetStringUTFLength: ?*anyopaque,

    // 169-170: GetStringUTFChars / ReleaseStringUTFChars — we use these
    GetStringUTFChars: ?*const fn (env: *JNIEnv, str: JString, is_copy: ?*JBoolean) callconv(.c) ?[*:0]const u8,
    ReleaseStringUTFChars: ?*const fn (env: *JNIEnv, str: JString, utf: [*:0]const u8) callconv(.c) void,

    // 171: GetArrayLength — typed (used by nif_screen_info).
    GetArrayLength: ?*const fn (env: *JNIEnv, arr: JObject) callconv(.c) JInt,

    // 172-178: ObjectArray + primitive-array constructors. NewByteArray is
    // typed because nif_vendor_usb_bulk_write needs it (Mob.VendorUsb's
    // raw-USB write path hands an iolist→binary across the JNI boundary
    // as a `byte[]`). The others stay opaque until something else needs
    // them.
    NewObjectArray: ?*anyopaque,
    GetObjectArrayElement: ?*anyopaque,
    SetObjectArrayElement: ?*anyopaque,
    NewBooleanArray: ?*anyopaque,
    NewByteArray: ?*const fn (env: *JNIEnv, len: JSize) callconv(.c) JByteArray,
    NewCharArray: ?*anyopaque,
    NewShortArray: ?*anyopaque,

    // 179-187: more New*Array + Get*ArrayElements.
    NewIntArray: ?*anyopaque,
    NewLongArray: ?*anyopaque,
    NewFloatArray: ?*anyopaque,
    NewDoubleArray: ?*anyopaque,
    GetBooleanArrayElements: ?*anyopaque,
    GetByteArrayElements: ?*anyopaque,
    GetCharArrayElements: ?*anyopaque,
    GetShortArrayElements: ?*anyopaque,
    GetIntArrayElements: ?*anyopaque,

    // 188-203: remaining Get*ArrayElements + all Release*ArrayElements +
    // Get*ArrayRegion entries up through GetFloatArrayRegion. We need
    // GetFloatArrayRegion (slot 203) typed for nif_screen_info /
    // nif_safe_area; everything between stays opaque.
    GetLongArrayElements: ?*anyopaque,
    GetFloatArrayElements: ?*anyopaque,
    GetDoubleArrayElements: ?*anyopaque,
    ReleaseBooleanArrayElements: ?*anyopaque,
    ReleaseByteArrayElements: ?*anyopaque,
    ReleaseCharArrayElements: ?*anyopaque,
    ReleaseShortArrayElements: ?*anyopaque,
    ReleaseIntArrayElements: ?*anyopaque,
    ReleaseLongArrayElements: ?*anyopaque,
    ReleaseFloatArrayElements: ?*anyopaque,
    ReleaseDoubleArrayElements: ?*anyopaque,
    GetBooleanArrayRegion: ?*anyopaque,
    GetByteArrayRegion: ?*anyopaque,
    GetCharArrayRegion: ?*anyopaque,
    GetShortArrayRegion: ?*anyopaque,
    GetIntArrayRegion: ?*anyopaque,
    GetLongArrayRegion: ?*anyopaque,
    GetFloatArrayRegion: ?*const fn (env: *JNIEnv, arr: JObject, start: JInt, len: JInt, buf: [*]f32) callconv(.c) void,
    GetDoubleArrayRegion: ?*anyopaque,

    // 204-211: SetXxxArrayRegion. SetByteArrayRegion is typed because
    // nif_vendor_usb_bulk_write copies BEAM-side bytes into a fresh
    // `byte[]` via NewByteArray + SetByteArrayRegion before the static
    // method call.
    SetBooleanArrayRegion: ?*anyopaque,
    SetByteArrayRegion: ?*const fn (env: *JNIEnv, arr: JByteArray, start: JSize, len: JSize, buf: [*]const JByte) callconv(.c) void,

    // The remaining ~25 slots (Set*ArrayRegion tail past byte,
    // RegisterNatives, MonitorEnter/Exit, GetJavaVM, NewWeakGlobalRef,
    // ExceptionCheck, DirectByteBuffer ops, GetObjectRefType) are not
    // used by mob_nif.zig today. Add when a later iter needs them — the
    // rule is "match jni.h up to the last USED slot".
};

/// JavaVM vtable — used for GetEnv / AttachCurrentThread / DetachCurrentThread.
pub const JavaVM = *const JNIInvokeInterface;

pub const JNIInvokeInterface = extern struct {
    _reserved0: ?*anyopaque,
    _reserved1: ?*anyopaque,
    _reserved2: ?*anyopaque,
    DestroyJavaVM: ?*anyopaque,
    AttachCurrentThread: ?*const fn (vm: *JavaVM, env: *?*JNIEnv, args: ?*anyopaque) callconv(.c) JInt,
    DetachCurrentThread: ?*const fn (vm: *JavaVM) callconv(.c) JInt,
    GetEnv: ?*const fn (vm: *JavaVM, env: *?*anyopaque, version: JInt) callconv(.c) JInt,
    AttachCurrentThreadAsDaemon: ?*anyopaque,
};

// ── Wrapper helpers (hide vtable indirection) ──────────────────────────────
// Each one-liner unwraps the JNIEnv vtable pointer and the function-pointer
// optional. Cuts call-site noise: `jni.findClass(env, "X")` vs
// `env.*.FindClass.?(env, "X")`.

pub inline fn findClass(env: *JNIEnv, name: [*:0]const u8) JClass {
    return env.*.FindClass.?(env, name);
}

pub inline fn getObjectClass(env: *JNIEnv, obj: JObject) JClass {
    return env.*.GetObjectClass.?(env, obj);
}

pub inline fn getMethodID(env: *JNIEnv, cls: JClass, name: [*:0]const u8, sig: [*:0]const u8) JMethodID {
    return env.*.GetMethodID.?(env, cls, name, sig);
}

pub inline fn getFieldID(env: *JNIEnv, cls: JClass, name: [*:0]const u8, sig: [*:0]const u8) JFieldID {
    return env.*.GetFieldID.?(env, cls, name, sig);
}

pub inline fn callObjectMethod(env: *JNIEnv, obj: JObject, mid: JMethodID) JObject {
    return env.*.CallObjectMethod.?(env, obj, mid);
}

pub inline fn callBooleanMethod(env: *JNIEnv, obj: JObject, mid: JMethodID) JBoolean {
    return env.*.CallBooleanMethod.?(env, obj, mid);
}

pub inline fn getObjectField(env: *JNIEnv, obj: JObject, fid: JFieldID) JObject {
    return env.*.GetObjectField.?(env, obj, fid);
}

pub inline fn getStringUTFChars(env: *JNIEnv, str: JString) ?[*:0]const u8 {
    return env.*.GetStringUTFChars.?(env, str, null);
}

pub inline fn releaseStringUTFChars(env: *JNIEnv, str: JString, utf: [*:0]const u8) void {
    env.*.ReleaseStringUTFChars.?(env, str, utf);
}

pub inline fn newGlobalRef(env: *JNIEnv, obj: JObject) JObject {
    return env.*.NewGlobalRef.?(env, obj);
}

// ── Static method helpers (added in iter 3b) ───────────────────────────────

pub inline fn getStaticMethodID(env: *JNIEnv, cls: JClass, name: [*:0]const u8, sig: [*:0]const u8) JMethodID {
    return env.*.GetStaticMethodID.?(env, cls, name, sig);
}

pub inline fn newStringUTF(env: *JNIEnv, utf: [*:0]const u8) JString {
    return env.*.NewStringUTF.?(env, utf);
}

pub inline fn deleteLocalRef(env: *JNIEnv, obj: JObject) void {
    env.*.DeleteLocalRef.?(env, obj);
}

pub inline fn exceptionClear(env: *JNIEnv) void {
    env.*.ExceptionClear.?(env);
}

pub inline fn getArrayLength(env: *JNIEnv, arr: JObject) JInt {
    return env.*.GetArrayLength.?(env, arr);
}

pub inline fn getFloatArrayRegion(env: *JNIEnv, arr: JObject, start: JInt, len: JInt, buf: [*]f32) void {
    env.*.GetFloatArrayRegion.?(env, arr, start, len, buf);
}

pub inline fn newByteArray(env: *JNIEnv, len: JSize) JByteArray {
    return env.*.NewByteArray.?(env, len);
}

pub inline fn setByteArrayRegion(env: *JNIEnv, arr: JByteArray, start: JSize, len: JSize, buf: [*]const JByte) void {
    env.*.SetByteArrayRegion.?(env, arr, start, len, buf);
}

pub inline fn getEnv(vm: *JavaVM, version: JInt) ?*JNIEnv {
    var env: ?*anyopaque = null;
    if (vm.*.GetEnv.?(vm, &env, version) != JNI_OK) return null;
    return @ptrCast(@alignCast(env));
}

pub inline fn attachCurrentThread(vm: *JavaVM) ?*JNIEnv {
    var env: ?*JNIEnv = null;
    if (vm.*.AttachCurrentThread.?(vm, &env, null) != JNI_OK) return null;
    return env;
}

pub inline fn detachCurrentThread(vm: *JavaVM) void {
    _ = vm.*.DetachCurrentThread.?(vm);
}

// ── Small string utilities ────────────────────────────────────────────────

/// Copy a NUL-terminated source string into a fixed-size buffer, truncating
/// (NUL-terminated) on overflow. Mirrors `snprintf(buf, sizeof(buf), "%s", src)`.
pub fn copyZ(buf: []u8, src: [*:0]const u8) void {
    var i: usize = 0;
    while (i < buf.len - 1 and src[i] != 0) : (i += 1) {
        buf[i] = src[i];
    }
    buf[i] = 0;
}

/// Compute the NUL-terminated length of a buffer (i.e. C strlen of buf[..]).
pub fn zLen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) : (i += 1) {}
    return i;
}

/// View a NUL-terminated buffer as a NUL-terminated [*:0]const u8.
/// The buffer must contain at least one NUL byte within its bounds.
pub fn asCStr(buf: []const u8) [*:0]const u8 {
    return @ptrCast(buf.ptr);
}
