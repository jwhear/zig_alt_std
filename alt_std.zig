
pub const algorithm = @import("alt_std/algorithm.zig");
pub const allocators = @import("alt_std/allocators.zig");
pub const levenshtein = @import("alt_std/levenshtein.zig");

test "run all tests" {
    comptime {
        @import("std").testing.refAllDeclsRecursive(@This());
    }
}
