const std = @import("std");

// A handle is a positive i32, so 31 bits to split between slot and generation.
// Slots were 8 bits (256), which a 200-row list overruns — every element past
// the cap got the -1 sentinel and silently stopped responding. 12 bits gives
// 4096, leaving 19 for the generation.
//
// Generation wrap is what the bit split trades against: at 60 fps, 2^19 frames
// is about 2.4 hours of continuous rendering before it wraps, and generationAge
// below is modular so a wrap is handled rather than merely survived. A handle
// is only meaningful for the frame it was minted in (or a run of frames where
// its PID and tag are unchanged), so hours of headroom is ample.
pub const slot_bits: u5 = 12;
pub const slot_count: usize = 1 << slot_bits;
pub const max_generation: u32 = (1 << (31 - @as(u32, slot_bits))) - 1;

pub const Decoded = struct {
    generation: u32,
    slot: usize,
};

pub fn encode(generation: u32, slot: usize) ?i32 {
    if (generation == 0 or generation > max_generation or slot >= slot_count) return null;
    const raw = (generation << slot_bits) | @as(u32, @intCast(slot));
    return @intCast(raw);
}

pub fn decode(handle: i32) ?Decoded {
    if (handle <= 0) return null;
    const raw: u32 = @intCast(handle);
    const generation = raw >> slot_bits;
    if (generation == 0) return null;
    return .{ .generation = generation, .slot = raw & (slot_count - 1) };
}

pub fn slotForActive(handle: i32, active_generation: u32, active_count: usize) ?usize {
    const decoded = decode(handle) orelse return null;
    if (decoded.generation != active_generation or decoded.slot >= active_count) return null;
    return decoded.slot;
}

pub fn nextGeneration(generation: u32) u32 {
    return if (generation == 0 or generation >= max_generation) 1 else generation + 1;
}

pub fn generationWithinIdentity(
    handle_generation: u32,
    identity_start_generation: u32,
    active_generation: u32,
) bool {
    if (handle_generation == 0 or handle_generation > max_generation or
        identity_start_generation == 0 or identity_start_generation > max_generation or
        active_generation == 0 or active_generation > max_generation)
    {
        return false;
    }

    return generationAge(active_generation, handle_generation) <=
        generationAge(active_generation, identity_start_generation);
}

fn generationAge(active_generation: u32, prior_generation: u32) u32 {
    return if (active_generation >= prior_generation)
        active_generation - prior_generation
    else
        max_generation - prior_generation + active_generation;
}

test "round trips every slot through a positive generation-tagged handle" {
    for (0..slot_count) |slot| {
        const handle = encode(42, slot).?;
        try std.testing.expect(handle > 0);
        try std.testing.expectEqual(Decoded{ .generation = 42, .slot = slot }, decode(handle).?);
    }
}

test "rejects invalid handles and encoding inputs" {
    try std.testing.expect(decode(-1) == null);
    try std.testing.expect(decode(0) == null);
    try std.testing.expect(encode(0, 0) == null);
    try std.testing.expect(encode(1, slot_count) == null);
    try std.testing.expect(encode(max_generation + 1, 0) == null);
}

test "validates generation and committed slot count together" {
    const handle = encode(9, 37).?;

    try std.testing.expectEqual(@as(?usize, 37), slotForActive(handle, 9, 38));
    try std.testing.expect(slotForActive(handle, 8, 38) == null);
    try std.testing.expect(slotForActive(handle, 9, 37) == null);
    try std.testing.expect(slotForActive(-1, 9, 38) == null);
}

test "generation wraps to one instead of producing invalid handles" {
    try std.testing.expectEqual(@as(u32, 2), nextGeneration(1));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(max_generation));
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(0));
}

test "identity range spans multiple renders and resets on replacement" {
    try std.testing.expect(generationWithinIdentity(10, 10, 15));
    try std.testing.expect(generationWithinIdentity(12, 10, 15));
    try std.testing.expect(generationWithinIdentity(15, 10, 15));
    try std.testing.expect(!generationWithinIdentity(9, 10, 15));

    try std.testing.expect(generationWithinIdentity(max_generation, max_generation - 1, 2));
    try std.testing.expect(generationWithinIdentity(1, max_generation - 1, 2));
    try std.testing.expect(!generationWithinIdentity(max_generation - 2, max_generation - 1, 2));
}

test "the bit split leaves a handle positive and keeps slot and generation independent" {
    // 31 usable bits in a positive i32. If these ever stop summing to 31, one
    // field silently starts eating the other's range.
    try std.testing.expectEqual(@as(u32, 31), @as(u32, slot_bits) + 19);
    try std.testing.expectEqual(@as(usize, 4096), slot_count);
    try std.testing.expectEqual(@as(u32, 0x7ffff), max_generation);

    // Every slot round-trips under the highest and lowest legal generations,
    // and the handle stays positive — a negative handle is the -1 "no handler"
    // sentinel, so a collision there would make a live element look inert.
    for ([_]u32{ 1, 2, max_generation / 2, max_generation }) |gen| {
        for ([_]usize{ 0, 1, 255, 256, 4094, slot_count - 1 }) |slot| {
            const h = encode(gen, slot).?;
            try std.testing.expect(h > 0);
            const d = decode(h).?;
            try std.testing.expectEqual(gen, d.generation);
            try std.testing.expectEqual(slot, d.slot);
        }
    }
}

test "a slot past the limit is refused rather than aliasing another slot" {
    // Before this widening the limit was 256 and everything past it got the
    // -1 sentinel and stopped responding. The limit is higher now, but it is
    // still a limit, and overrunning it must not silently wrap onto slot 0.
    try std.testing.expect(encode(1, slot_count) == null);
    try std.testing.expect(encode(1, slot_count + 1) == null);
    try std.testing.expect(encode(1, 99_999) == null);
    try std.testing.expect(encode(max_generation + 1, 0) == null);
    try std.testing.expect(encode(0, 0) == null);
}

test "handles minted under the old 8-bit split do not resolve as valid today" {
    // Purely a documentation test: an 8-bit-split handle decodes to a different
    // (generation, slot) pair under the 12-bit split, so a stale handle from a
    // pre-upgrade build cannot be mistaken for a live one. Generations are
    // per-render and start at 1 on boot, so this can only matter across a hot
    // code swap, but the property is cheap to state.
    const old_style: i32 = (42 << 8) | 7; // generation 42, slot 7, old split
    const d = decode(old_style).?;
    try std.testing.expect(d.generation != 42 or d.slot != 7);
}
