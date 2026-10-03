// mob_stored_queue.h — what native code keeps for the :mob_screen router
// while the router can't take it: notification envelopes and opened links
// that arrive before erts is up (the tap or link that cold-launched the app)
// or while it starts. The router drains a queue when it starts, one entry per
// take NIF call (decisions/2026-10-01-notification-delivery-envelope.md,
// decisions/2026-10-03-deep-link-delivery.md). mob_nif.m keeps one queue per
// kind; android/jni/mob_stored_queue.zig is the Android twin.
//
// A FIFO, not one slot: a foreground arrival during boot must not displace the
// tap that launched the app. When it is full (a router that never starts) the
// newest entry is refused, so whatever launched the app is kept.
//
// Plain C so test/native/stored_queue_test.c can run it on the host.

#ifndef MOB_STORED_QUEUE_H
#define MOB_STORED_QUEUE_H

#include <os/lock.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define MOB_STORED_MAX 16

typedef struct {
    char *items[MOB_STORED_MAX];
    size_t head;
    size_t count;
    // Not an ErlNifMutex: entries are stored before erts exists and while it
    // is still starting, so the lock has to work then.
    os_unfair_lock lock;
} MobStoredQueue;

#define MOB_STORED_QUEUE_INIT {.lock = OS_UNFAIR_LOCK_INIT}

// Appends a copy of `s`. false when the queue is full or the copy can't be
// made; the caller logs it.
static inline bool mob_stored_push(MobStoredQueue *q, const char *s) {
    char *copy = strdup(s);
    if (!copy)
        return false;
    os_unfair_lock_lock(&q->lock);
    bool stored = q->count < MOB_STORED_MAX;
    if (stored) {
        q->items[(q->head + q->count) % MOB_STORED_MAX] = copy;
        q->count++;
    }
    os_unfair_lock_unlock(&q->lock);
    if (!stored)
        free(copy);
    return stored;
}

// The oldest entry, or NULL. The caller frees it.
static inline char *mob_stored_pop(MobStoredQueue *q) {
    os_unfair_lock_lock(&q->lock);
    char *s = NULL;
    if (q->count > 0) {
        s = q->items[q->head];
        q->items[q->head] = NULL;
        q->head = (q->head + 1) % MOB_STORED_MAX;
        q->count--;
    }
    os_unfair_lock_unlock(&q->lock);
    return s;
}

// Frees every entry under one hold of the lock, so an entry pushed
// concurrently lands after the clear and survives it.
static inline void mob_stored_clear(MobStoredQueue *q) {
    os_unfair_lock_lock(&q->lock);
    while (q->count > 0) {
        free(q->items[q->head]);
        q->items[q->head] = NULL;
        q->head = (q->head + 1) % MOB_STORED_MAX;
        q->count--;
    }
    os_unfair_lock_unlock(&q->lock);
}

#endif // MOB_STORED_QUEUE_H
