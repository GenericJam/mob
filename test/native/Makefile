# Native-side checks that can run on the host (no simulator, no XCTest target).
#
#   make run    build + run everything here
#   make clean
#
# Each test file's header says what it does and does not cover.

CC      ?= clang
CFLAGS  ?= -fobjc-arc -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?= -framework Foundation

BINS := frame_registry_test dist_port_test dist_cookie_test stored_queue_test init_args_test

.PHONY: run clean
run: $(BINS)
	@for b in $(BINS); do echo "== $$b"; ./$$b || exit 1; done

frame_registry_test: frame_registry_test.m
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

dist_port_test: dist_port_test.c ../../ios/mob_dist_port.h
	$(CC) -Wall -Wextra -Werror $< -o $@

dist_cookie_test: dist_cookie_test.c ../../ios/mob_dist_cookie.h
	$(CC) -Wall -Wextra -Werror $< -o $@

stored_queue_test: stored_queue_test.c ../../ios/mob_stored_queue.h
	$(CC) -Wall -Wextra -Werror -pthread $< -o $@

init_args_test: init_args_test.c ../../ios/mob_init_args.h
	$(CC) -Wall -Wextra -Werror $< -o $@

clean:
	rm -f $(BINS)
