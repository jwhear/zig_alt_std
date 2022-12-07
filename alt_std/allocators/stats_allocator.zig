
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Which statistics should be tracked.  By default all are false (do not track)
///  to make positive selection easy, e.g. `.{ .allocs = true, .frees = true}`
/// Use `Tracking.all()` to track all statistics.
pub const Tracking = struct {
    /// Track the number of calls to `alloc`
    allocs: bool = false,
    /// Track the number of calls to `resize`
    resizes: bool = false,
    /// Track the number of calls to `free`
    frees: bool = false,

    /// Track the number of failed calls to `alloc`
    alloc_failures: bool = false,
    /// Track the number of failed calls to `resize`
    resize_failures: bool = false,

    /// Track bytes requested by calls to `alloc`
    bytes_requested: bool = false,
    /// Track bytes successfully returned by `alloc`
    bytes_allocated: bool = false,
    /// Track bytes added by calls to `resize`
    bytes_grown: bool = false,
    /// Track bytes removed by calls to `resize`
    bytes_shrunk: bool = false,
    /// Track bytes removed by calls to `free`
    bytes_freed: bool = false,

    /// Track the maximum number of bytes allocated at a single time
    bytes_high_water_mark: bool = false,

    /// Returns a Tracking with all statistics enabled
    pub fn all() Tracking {
        var ret: Tracking = .{};
        inline for (comptime std.meta.fieldNames(Tracking)) |name| {
            @field(ret, name) = true;
        }
        return ret;
    }

    /// Returns the number of statistics being tracked
    pub fn count(self: Tracking) usize {
        var ret: usize = 0;
        inline for (comptime std.meta.fieldNames(Tracking)) |name| {
            if (@field(self, name)) ret += 1;
        }
        return ret;
    }
};

/// Holds counters for the statistics selected by `track`.
/// Unwanted statistics have type `void` and use no memory.
///
/// You can determine whether a counter is active or not by checking via `tracking`:
/// ```zig
/// const MyStats = Stats(.{ .allocs = true });
/// if (MyStats.tracking.allocs) {...}
/// ```
pub fn Stats(comptime track: Tracking) type {
    return struct {
        const Self = @This();

        ///
        pub const tracking = track;

        /// The number of calls to `alloc`
        allocs: if (track.allocs) usize else void = if (track.allocs) 0 else {},
        /// The number of calls to `resize`
        resizes: if (track.resizes) usize else void = if (track.resizes) 0 else {},
        /// The number of calls to `free`
        frees: if (track.frees) usize else void = if (track.frees) 0 else {},

        /// The number of failed calls to `alloc`
        alloc_failures: if (track.alloc_failures) usize else void = if (track.alloc_failures) 0 else {},
        /// The number of failed calls to `resize`
        resize_failures: if (track.resize_failures) usize else void = if (track.resize_failures) 0 else {},

        /// Bytes requested by calls to `alloc`
        bytes_requested: if (track.bytes_requested) usize else void = if (track.bytes_requested) 0 else {},
        /// Bytes successfully returned by `alloc`
        bytes_allocated: if (track.bytes_allocated) usize else void = if (track.bytes_allocated) 0 else {},
        /// Bytes added by calls to `resize`
        bytes_grown: if (track.bytes_grown) usize else void = if (track.bytes_grown) 0 else {},
        /// Bytes removed by calls to `resize`
        bytes_shrunk: if (track.bytes_shrunk) usize else void = if (track.bytes_shrunk) 0 else {},
        /// Bytes removed by calls to `free`
        bytes_freed: if (track.bytes_freed) usize else void = if (track.bytes_freed) 0 else {},

        /// The maximum number of bytes allocated at a single time
        /// Note that this will only work if also tracking bytes_allocated,
        ///  bytes_grown, bytes_shrunk, and bytes_freed
        bytes_high_water_mark: if (track.bytes_high_water_mark) usize else void = if (track.bytes_high_water_mark) 0 else {},

        /// Returns the number of bytes currently allocated, including those
        ///  claimed by calls to `resize`.  Note that this does not capture
        ///  additional memory that may be in use due to bookkeeping or alignment.
        /// This method returns zero if any of the following are not tracked:
        ///  bytes_allocated, bytes_grown, bytes_shrunk, bytes_freed
        pub fn bytesInUse(self: Self) usize {
            const tracking_needed = comptime (
                isTracking("bytes_allocated") and
                isTracking("bytes_grown") and
                isTracking("bytes_shrunk") and
                isTracking("bytes_freed")
            );
            return if (comptime tracking_needed)
                self.bytes_allocated + self.bytes_grown - self.bytes_shrunk - self.bytes_freed
            else 0;
        }

        /// Because fields are defined as `void` if not tracked, it may be
        ///  more convenient to use this method which will return zero if the
        ///  statistic was not tracked.
        pub fn get(self: Self, comptime counter_name: []const u8) usize {
            return if (comptime isTracking(counter_name)) @field(self, counter_name) else 0;
        }

        fn isTracking(comptime counter_name: []const u8) bool {
            return @field(track, counter_name);
        }

        fn maybeSetHWM(self: *Self) void {
            if (comptime isTracking("bytes_high_water_mark")) {
                self.bytes_high_water_mark = std.math.max(self.bytes_high_water_mark, self.bytesInUse());
            }
        }

        fn add(self: *Self, comptime counter_name: []const u8, amount: usize) void {
            // If `counter_name` is not being tracked this function should become
            //  a noop and the call removed at compile-time.
            if (comptime isTracking(counter_name)) {
                @field(self, counter_name) += amount;
            }
        }
    };
}

/// This allocator wraps another allocator and forwards all requests to it,
///  tracking various statistics.
///
/// The underlying allocator may use some bytes for bookkeeping or have "slack"
///  bytes due to alignment requests: the tracking in this allocator is not
///  aware of those bytes, it can only track the actual requests made.
///
/// Because each statistic tracked requires a `usize` counter, tracking all
///  statistics leads to a rather heavy allocator--it's recommended that you
///  request only the statistics that are useful to you.  Untracked statistics
///  should have zero memory or CPU overhead at runtime.  A StatsAllocator
///  with nothing tracked has zero overhead as the call to `allocator` simply
///  returns the underlying backing allocator.
pub fn StatsAllocator(comptime track: Tracking) type {
    return struct {
        const Self = @This();

        ///
        backing_allocator: Allocator,

        ///
        stats: Stats(track),


        ///
        pub fn init(backing_allocator: Allocator) Self {
            return .{
                .backing_allocator = backing_allocator,
                .stats = .{},
            };
        }

        ///
        pub fn allocator(self: *Self) Allocator {
            // As an optimization, if no statistics are being tracked simply
            //  return the backing allocator.  This allows us to avoid the
            //  overhead of another layer of function pointer indirection
            return if (comptime track.count() == 0)
                       self.backing_allocator
                   else
                        Allocator{
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

            self.stats.add("allocs", 1);
            self.stats.add("bytes_requested", n);
            const ret = self.backing_allocator.vtable.alloc(self.backing_allocator.ptr, n, log2_ptr_align, ra);

            if (ret == null) {
                self.stats.add("alloc_failures", 1);
            } else {
                self.stats.add("bytes_allocated", n);
                self.stats.maybeSetHWM();
            }

            return ret;
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_size: usize, ra: usize) bool {
            const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));

            self.stats.add("resizes", 1);
            const ret = self.backing_allocator.vtable.resize(self.backing_allocator.ptr, buf, buf_align, new_size, ra);

            if (ret) {
                if (new_size > buf.len) {
                    self.stats.add("bytes_grown", new_size - buf.len);
                    self.stats.maybeSetHWM();
                } else {
                    self.stats.add("bytes_shrunk", buf.len - new_size);
                }
            } else {
                self.stats.add("resize_failures", 1);
            }

            return ret;
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ra: usize) void {
            const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
            self.stats.add("frees", 1);

            self.backing_allocator.vtable.free(self.backing_allocator.ptr, buf, buf_align, ra);
            self.stats.add("bytes_freed", buf.len);
        }
    };
}

test "StatsAllocator: no overhead" {
    var backing = std.heap.GeneralPurposeAllocator(.{}){};
    var statsAllocator = StatsAllocator(.{}).init(backing.allocator());

    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(statsAllocator.stats)));

    const ally = statsAllocator.allocator();
    const alloc1 = try ally.alloc(u8, 10);
    ally.free(alloc1);
}

test "StatsAllocator: track all" {
    var backing = std.heap.GeneralPurposeAllocator(.{}){};
    var statsAllocator = StatsAllocator(Tracking.all()).init(backing.allocator());

    const ally = statsAllocator.allocator();
    var alloc1 = try ally.alloc(u8, 10);
    try std.testing.expectEqual(@as(usize, 1), statsAllocator.stats.allocs);
    try std.testing.expectEqual(@as(usize, 10), statsAllocator.stats.bytes_allocated);
    try std.testing.expectEqual(@as(usize, 10), statsAllocator.stats.bytesInUse());

    // grow it
    try std.testing.expect(ally.resize(alloc1, 15));
    alloc1 = alloc1.ptr[0..15];
    try std.testing.expectEqual(@as(usize, 1), statsAllocator.stats.resizes);
    try std.testing.expectEqual(@as(usize, 5), statsAllocator.stats.bytes_grown);
    try std.testing.expectEqual(@as(usize, 15), statsAllocator.stats.bytesInUse());

    // shrink it
    try std.testing.expect(ally.resize(alloc1, 5));
    alloc1 = alloc1.ptr[0..5];
    try std.testing.expectEqual(@as(usize, 2), statsAllocator.stats.resizes);
    try std.testing.expectEqual(@as(usize, 10), statsAllocator.stats.bytes_shrunk);
    try std.testing.expectEqual(@as(usize, 5), statsAllocator.stats.bytesInUse());

    // free it
    ally.free(alloc1);
    try std.testing.expectEqual(@as(usize, 1), statsAllocator.stats.frees);
    try std.testing.expectEqual(@as(usize, 5), statsAllocator.stats.bytes_freed);
    try std.testing.expectEqual(@as(usize, 0), statsAllocator.stats.bytesInUse());

    // High water mark?
    try std.testing.expectEqual(@as(usize, 15), statsAllocator.stats.bytes_high_water_mark);
}
