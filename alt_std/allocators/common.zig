const std = @import("std");

/// This is like std.math.divCeil but specialized for usize and unable to error
/// Caller is responsible for ensuring that `den > 0`
pub fn divideRoundUp(num: usize, den: usize) usize
{
    std.debug.assert(den > 0);
    if (num == 0) return 0;
    return @divFloor(num - 1, den) + 1;
}
test "divideRoundUp" {
    try std.testing.expectEqual(@as(usize, 0), divideRoundUp(0, 16));
    try std.testing.expectEqual(@as(usize, 1), divideRoundUp(1, 16));
    try std.testing.expectEqual(@as(usize, 1), divideRoundUp(2, 16));
    try std.testing.expectEqual(@as(usize, 1), divideRoundUp(16, 16));
    try std.testing.expectEqual(@as(usize, 2), divideRoundUp(17, 16));
    try std.testing.expectEqual(@as(usize, 2), divideRoundUp(31, 16));
    try std.testing.expectEqual(@as(usize, 2), divideRoundUp(32, 16));
}

pub fn sliceContainsPtr(container: []u8, ptr: [*]u8) bool {
    return @ptrToInt(ptr) >= @ptrToInt(container.ptr) and
        @ptrToInt(ptr) < (@ptrToInt(container.ptr) + container.len);
}

pub fn sliceContainsSlice(container: []u8, slice: []u8) bool {
    return @ptrToInt(slice.ptr) >= @ptrToInt(container.ptr) and
        (@ptrToInt(slice.ptr) + slice.len) <= (@ptrToInt(container.ptr) + container.len);
}
