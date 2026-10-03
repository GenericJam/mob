// The iOS FIFO that holds notifications and opened links for the router
// (MOB-379).
//
//     make -C test/native run
//
// Compiles ios/mob_stored_queue.h itself, the code mob_nif.m runs. It does not
// cover mob_nif.m's use of it (sending to the router, the take NIFs); the
// router side is test/mob/router/link_test.exs and notification_test.exs.
// android/jni/mob_stored_queue.zig has the same tests for Android (zig test).
#include "../../ios/mob_stored_queue.h"

#include <pthread.h>
#include <stdio.h>

static int failures = 0;

#define CHECK(cond, ...)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                                   \
            fprintf(stderr, __VA_ARGS__);                                                          \
            fprintf(stderr, "\n");                                                                 \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

// Pops one entry and checks it, freeing it.
static void expect_pop(MobStoredQueue *q, const char *expected) {
    char *s = mob_stored_pop(q);
    CHECK(s != NULL, "expected %s, queue empty", expected);
    if (s) {
        CHECK(strcmp(s, expected) == 0, "expected %s, got %s", expected, s);
        free(s);
    }
}

static void test_fifo_across_the_wrap(void) {
    MobStoredQueue q = MOB_STORED_QUEUE_INIT;
    // Move head past the start so the next pushes wrap around the ring.
    for (int i = 0; i < MOB_STORED_MAX - 2; i++)
        CHECK(mob_stored_push(&q, "old"), "push old %d", i);
    for (int i = 0; i < MOB_STORED_MAX - 2; i++)
        expect_pop(&q, "old");

    CHECK(mob_stored_push(&q, "a"), "push a");
    CHECK(mob_stored_push(&q, "b"), "push b");
    CHECK(mob_stored_push(&q, "c"), "push c");
    expect_pop(&q, "a");
    expect_pop(&q, "b");
    expect_pop(&q, "c");
    CHECK(mob_stored_pop(&q) == NULL, "empty after draining");
}

// The tap or link that launched the app is the oldest entry; a burst after it
// must not displace it.
static void test_full_refuses_the_newest(void) {
    MobStoredQueue q = MOB_STORED_QUEUE_INIT;
    CHECK(mob_stored_push(&q, "launch"), "push launch");
    for (int i = 1; i < MOB_STORED_MAX; i++)
        CHECK(mob_stored_push(&q, "later"), "push later %d", i);
    CHECK(!mob_stored_push(&q, "overflow"), "a full queue refuses");

    expect_pop(&q, "launch");
    for (int i = 1; i < MOB_STORED_MAX; i++)
        expect_pop(&q, "later");
    CHECK(mob_stored_pop(&q) == NULL, "the refused entry was not kept");
}

static void test_push_copies(void) {
    MobStoredQueue q = MOB_STORED_QUEUE_INIT;
    char url[] = "myapp://x";
    CHECK(mob_stored_push(&q, url), "push");
    url[0] = 'X';
    expect_pop(&q, "myapp://x");
}

static void test_clear_empties_and_the_queue_keeps_working(void) {
    MobStoredQueue q = MOB_STORED_QUEUE_INIT;
    CHECK(mob_stored_push(&q, "w"), "push w");
    expect_pop(&q, "w");
    CHECK(mob_stored_push(&q, "x"), "push x");
    CHECK(mob_stored_push(&q, "y"), "push y");

    mob_stored_clear(&q);
    CHECK(mob_stored_pop(&q) == NULL, "empty after clear");

    CHECK(mob_stored_push(&q, "z"), "push after clear");
    expect_pop(&q, "z");
}

static void test_queues_are_independent(void) {
    MobStoredQueue notifications = MOB_STORED_QUEUE_INIT;
    MobStoredQueue links = MOB_STORED_QUEUE_INIT;
    CHECK(mob_stored_push(&notifications, "{\"id\":\"n1\"}"), "push notification");
    CHECK(mob_stored_push(&links, "myapp://x"), "push link");

    expect_pop(&links, "myapp://x");
    CHECK(mob_stored_pop(&links) == NULL, "links holds only the link");
    expect_pop(&notifications, "{\"id\":\"n1\"}");
}

// Native code stores from the main thread while the router takes from a BEAM
// scheduler. Every entry pushed is popped exactly once.
#define WRITERS 4
#define PER_WRITER 4 // WRITERS * PER_WRITER == MOB_STORED_MAX: nothing refused

static MobStoredQueue g_shared = MOB_STORED_QUEUE_INIT;

static void *writer(void *arg) {
    long id = (long)arg;
    char entry[16];
    for (int i = 0; i < PER_WRITER; i++) {
        snprintf(entry, sizeof(entry), "%ld-%d", id, i);
        CHECK(mob_stored_push(&g_shared, entry), "push %s", entry);
    }
    return NULL;
}

static void test_concurrent_writers_lose_nothing(void) {
    pthread_t threads[WRITERS];
    for (long i = 0; i < WRITERS; i++)
        pthread_create(&threads[i], NULL, writer, (void *)i);
    for (int i = 0; i < WRITERS; i++)
        pthread_join(threads[i], NULL);

    int seen[WRITERS][PER_WRITER] = {{0}};
    int last[WRITERS] = {-1, -1, -1, -1};
    char *s;
    int popped = 0;
    while ((s = mob_stored_pop(&g_shared))) {
        long id;
        int i;
        if (sscanf(s, "%ld-%d", &id, &i) == 2 && id >= 0 && id < WRITERS && i >= 0 &&
            i < PER_WRITER) {
            seen[id][i]++;
            // One writer's entries stay in the order it pushed them.
            CHECK(i > last[id], "writer %ld: %d after %d", id, i, last[id]);
            last[id] = i;
        }
        free(s);
        popped++;
    }
    CHECK(popped == WRITERS * PER_WRITER, "popped %d", popped);
    for (int id = 0; id < WRITERS; id++)
        for (int i = 0; i < PER_WRITER; i++)
            CHECK(seen[id][i] == 1, "%d-%d seen %d times", id, i, seen[id][i]);
}

int main(void) {
    test_fifo_across_the_wrap();
    test_full_refuses_the_newest();
    test_push_copies();
    test_clear_empties_and_the_queue_keeps_working();
    test_queues_are_independent();
    test_concurrent_writers_lose_nothing();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("stored_queue_test: ok\n");
    return 0;
}
