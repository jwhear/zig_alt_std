
pub const algorithm = @import("alt_std/algorithm.zig");

test "run all tests" {
    @import("std").testing.refAllDeclsRecursive(@This());
}
