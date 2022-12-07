//! BucketingAllocator combines multiple allocators, distributing allocations to
//!  them based on the requested size.  This is frequently desirable to minimize
//!  bookkeeping overhead, e.g. small allocations might benefit from a
//!  BitmapBlockAllocator while large allocations might use a GeneralPurposeAllocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Defines an allocation range.  The size of allocations covered by a bucket's
///  allocator is [min, max), so it will serve requests `min <= request_size < max`
pub const Bucket = struct {
    ///
    allocator: Allocator,
    ///
    min: usize,
    ///
    max: usize,

    /// Convenience method for constructing a final "catch-all" bucket.
    pub fn trailer(a: Allocator, min: usize) Bucket {
        return Bucket{
            .allocator = a,
            .min = min,
            .max = std.math.maxInt(usize),
        };
    }

    /// Returns true if this bucket serves requests of `size`.
    pub fn accepts(self: Bucket, size: usize) bool {
        return self.min <= size and size < self.max;
    }
};

const Self = @This();

///
buckets: []Bucket,

/// Takes a slice of `Bucket`.  The buckets should not overlap, i.e. multiple
///  buckets should not accept the same request size.
/// Because the Allocator interface does not expose a method for deiniting,
///  this allocator does not have a `deinit` method.  The caller is responsible
///  for any cleanup of the allocator within the buckets.
pub fn init(buckets: []Bucket) Self {
    return .{
        .buckets = buckets,
    };
}

/// Returns the bucket responsible for allocations of `size`.
/// Returns null if no such bucket has been defined.
pub fn getBucketFor(self: *Self, size: usize) ?Bucket {
    for (self.buckets) |bucket| {
        if (bucket.accepts(size)) return bucket;
    }
    return null;
}

///
pub fn allocator(self: *Self) Allocator {
    return Allocator{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free
        },
    };
}

fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
    const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
    const backing = (self.getBucketFor(n) orelse return null).allocator;
    return backing.vtable.alloc(backing.ptr, n, log2_ptr_align, ra);
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_size: usize, ra: usize) bool {
    const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
    const current_bucket = self.getBucketFor(buf.len) orelse return false;

    // resize guarantees that buf.ptr won't be relocated, so we have to reject
    //  any resizes that can't be accommodated by the current bucket
    if (!current_bucket.accepts(new_size)) return false;

    var ally = current_bucket.allocator;
    return ally.vtable.resize(ally.ptr, buf, buf_align, new_size, ra);
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ra: usize) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
    const backing = (self.getBucketFor(buf.len) orelse
        std.debug.panic("No allocator for requested free", .{})).allocator;

    backing.vtable.free(backing.ptr, buf, buf_align, ra);
}


test "BucketingAllocator" {
    const BBA = @import("BitmapBlockAllocator.zig");

    // Define three different allocators for various sizes of requests
    var small_buf: [1024]u8 = undefined;
    var small = BBA.init(&small_buf, 8, 125);

    var med_buf: [1024]u8 = undefined;
    var med = BBA.init(&med_buf, 32, 30);

    var big = std.heap.GeneralPurposeAllocator(.{}){};

    // Bucketing
    var ba = Self.init(&[_]Bucket{
        .{ .min=0,   .max=16, .allocator=small.allocator()},
        .{ .min=16,  .max=128, .allocator=med.allocator()},
        Bucket.trailer(big.allocator(), 128),
    });

    // Verify that trailer works
    try std.testing.expect(ba.buckets[ba.buckets.len-1].accepts(1024));

    var ally = ba.allocator();

    var small_alloc1 = try std.fmt.allocPrint(ally, "Tiny: {}", .{100});
    const med_alloc1 = try std.fmt.allocPrint(ally, "This takes more than 16 bytes: {}", .{100});
    const big_alloc1 = try ally.alloc(u8, 1024);

    try std.testing.expect(small.ownsSlice(small_alloc1));
    try std.testing.expect(med.ownsSlice(med_alloc1));
    try std.testing.expect(!small.ownsSlice(big_alloc1));
    try std.testing.expect(!med.ownsSlice(big_alloc1));

    // How about resizing?
    // First a reasonable request that can be accommodated
    try std.testing.expect(ally.resize(small_alloc1, 15));
    try std.testing.expect(small.ownsSlice(small_alloc1));
    // Now one that is slightly too large, should be rejected
    try std.testing.expect(!ally.resize(small_alloc1, 16));
    try std.testing.expect(small.ownsSlice(small_alloc1));

    // Freeing?
    ally.free(small_alloc1);
    ally.free(med_alloc1);
    ally.free(big_alloc1);

    try std.testing.expectEqual(@as(usize, 0), small.getUsage().used_blocks);
    try std.testing.expectEqual(@as(usize, 0), med.getUsage().used_blocks);
}
