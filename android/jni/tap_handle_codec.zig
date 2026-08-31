const std = @import("std");

pub const slot_count: usize = 256;
pub const max_generation: u32 = 0x7fffff;

pub const Decoded = struct {
    generation: u32,
    slot: usize,
};

pub fn encode(generation: u32, slot: usize) ?i32 {
    if (generation == 0 or generation > max_generation or slot >= slot_count) return null;
    const raw = (generation << 8) | @as(u32, @intCast(slot));
    return @intCast(raw);
}

pub fn decode(handle: i32) ?Decoded {
    if (handle <= 0) return null;
    const raw: u32 = @intCast(handle);
    const generation = raw >> 8;
    if (generation == 0) return null;
    return .{ .generation = generation, .slot = raw & 0xff };
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
