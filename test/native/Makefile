# Native-side checks that can run on the host (no simulator, no XCTest target).
#
#   make run    build + run everything here
#   make clean
#
# See frame_registry_test.m for what this does and does not cover.

CC      ?= clang
CFLAGS  ?= -fobjc-arc -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?= -framework Foundation

BINS := frame_registry_test

.PHONY: run clean
run: $(BINS)
	@for b in $(BINS); do echo "== $$b"; ./$$b || exit 1; done

frame_registry_test: frame_registry_test.m
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

clean:
	rm -f $(BINS)
