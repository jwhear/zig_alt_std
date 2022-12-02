//! This Allocator takes a buffer and allocates from it, tracking fixed-size blocks.
//! It can allocate chunks of memory larger than `block_size` by claiming multiple
//!  consecutive blocks, but every allocation, no matter how small, will claim
//!  a whole block.
//! Bookkeeping is kept to a minimum by using a single bit per block to track
//!  whether it is allocated or not.  This also has the advantage of automatically
//!  defragmenting as freed blocks automatically "merge" with their free neighbors.
//! Finding a free sequence of blocks is O(n) but is very efficient as it only
//!  requires searching a relatively small bitmap with excellent memory coherence.
//!
//! When to use this allocator:
//! Allocations are relatively small (as a multiple of `block_size`), but not so
//!  small that claimed blocks waste lots of empty space.  In the optimal case,
//!  all allocations are exactly `block_size` in which case every allocation
//!  wastes no allocation space and has a single bit of bookkeeping overhead.
//! As an example, a 1024 byte buffer given to this allocator with a block_size
//!  of 16 bytes will support 63 blocks; in other words, 1008 allocatable bytes
//!  with 16 bytes of bookkeeping (2.03 bits/allocation).
//! Larger buffers push this efficiency higher, e.g. a 4096 byte buffer with 16
//!  byte blocks supports up to 253 allocations; 4064 bytes are allocatable with
//!  32 bytes of bookkeeping for an overhead of 1.011 bits/allocation.
//! 
//! When not to use this allocator:
//! Allocations are large but relatively few; this usage will drive the bookkeeping
//!  bits per allocation high and lead to longer searches.

const std = @import("std");
const common = @import("common.zig");
const Allocator = std.mem.Allocator;

const usize_bytes = @bitSizeOf(usize) / 8;

// Set to true for printf debugging
const debug_output = false;

const Self = @This();
const BitSet = std.bit_set.DynamicBitSetUnmanaged;

// This bitmap should only be modified by the markBlocks function to ensure
//  that the first_available_block field is kept up to date.
in_use_bitmap: BitSet,

// A slice of the buffer passed at initialization.  Does not include the
//  storage of the bitmap, only the actual allocations
allocations: []u8,
block_size: usize,

// This is an optimization: because we always use the first available block,
//  most allocations will live near the front of the allocations buffer.
// By tracking and consistently updating this index we can start our search
//  nearer a suitable position, and for allocations that will fit in a single
//  block, we won't have to search at all.
first_available_block: usize,

/// Return instance of this allocator.
/// - The caller is responsible for freeing `buffer`
/// - `block_size` is the number of bytes per block
/// - `n_blocks_desired` is the number of blocks this allocator should manage
///
/// `buffer.len` must be at least the result of calling `bufferSizeRequired`
///   with the same `block_size` and `n_blocks_desired` arguments.
///
/// See also `initAlloc`
pub fn init(buffer: []u8, block_size: usize, n_blocks_desired: usize) Self {
    std.debug.assert(block_size >= 1);
    std.debug.assert(n_blocks_desired >= 1);
    std.debug.assert(buffer.len >= bufferSizeRequired(block_size, n_blocks_desired));

    // We'll use this allocator to create the bitmap but, because we never
    //  need to grow or free the bitmap (it lives in the `buffer` slice),
    //  we don't need to store this allocator for later.
    var fba = std.heap.FixedBufferAllocator.init(buffer);

    // Find the number of actually usuable blocks.  This is dynamic problem
    //  because the more blocks, the bigger in_use_bitmap needs to be which
    //  consumes more of buffer, leaving less for blocks...
    return .{
        .in_use_bitmap = BitSet.initEmpty(fba.allocator(), n_blocks_desired) catch unreachable,
        .allocations = buffer[fba.end_index..],
        .block_size = block_size,
        .first_available_block = 0,
    };
}

/// Uses `backing_allocator` to acquire a buffer large enough to allocate
///  at least `allocatable_size` bytes.  Note that if all allocations are
///  exactly multiples of `block_size`, this allocator will likely fail
///  before actually allocating `allocatable_size`.
pub fn initAlloc(backing_allocator: Allocator, block_size: usize, allocatable_size: usize) !Self {
    std.debug.assert(block_size >= 1);
    std.debug.assert(allocatable_size >= block_size);

    const n_blocks_desired = common.divideRoundUp(allocatable_size, block_size);
    const buf_len = bufferSizeRequired(block_size, n_blocks_desired);
    return init(
        try backing_allocator.alloc(u8, buf_len),
        block_size,
        n_blocks_desired,
    );
}

///
pub fn deinit(self: *Self) void {
    // We don't actually need to clean anything up
    _=self;
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

/// Returns true if the pointer points to memory under this allocator's control
pub fn ownsPtr(self: *Self, ptr: [*]u8) bool {
    return common.sliceContainsPtr(self.allocations, ptr);
}

/// Return true if the slice is part of the memory under this allocator's control
pub fn ownsSlice(self: *Self, slice: []u8) bool {
    return common.sliceContainsSlice(self.allocations, slice);
}

/// Because this allocator uses part of the supplied buffer for bookkeeping,
///  use this function to determine how large of a buffer is needed to supply a
///  desired number of blocks.
/// Returns number of bytes required.
pub fn bufferSizeRequired(block_size: usize, n_blocks_desired: usize) usize {
    return bitmapBytesRequired(n_blocks_desired) + n_blocks_desired * block_size;
}

///
pub fn blockSize(self: Self) usize {
    return self.block_size;
}

///
pub const Usage = struct {
    ///
    used_blocks: usize,
    ///
    free_blocks: usize,
    ///
    block_size: usize,

    ///
    pub fn usedBytes(self: Usage) usize {
        return self.used_blocks * self.block_size;
    }

    ///
    pub fn freeBytes(self: Usage) usize {
        return self.free_blocks * self.block_size;
    }
};

/// Returns information about free and used blocks/bytes
pub fn getUsage(self: Self) Usage {
    const used = self.in_use_bitmap.count();
    return .{
        .used_blocks = used,
        .free_blocks = self.in_use_bitmap.capacity() - used,
        .block_size = self.block_size,
    };
}

/// Marks all blocks as available
pub fn freeAll(self: *Self) void {
    self.in_use_bitmap.setRangeValue(
        .{ .start = 0, .end = self.in_use_bitmap.capacity() },
        false
    );
}

fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
    const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
    const ptr_align = @as(usize, 1) << @intCast(Allocator.Log2Align, log2_ptr_align);
    _ = ra;

    var index = self.first_available_block;
    while (index < self.in_use_bitmap.capacity()) : (index += 1) {
        if (self.in_use_bitmap.isSet(index)) continue;

        var block = self.getBlock(index);
        const add_to_align = std.mem.alignForward(@ptrToInt(block.ptr), ptr_align) - @ptrToInt(block.ptr);

        // How many total sequential blocks do we need to fit this request?
        const bytes_needed = add_to_align + n;
        const blocks_needed = common.divideRoundUp(bytes_needed, self.block_size);


        // Do we have that many available blocks starting with this one?
        const available_blocks = self.countAvailableBlocks(index, blocks_needed);

        // If not enough blocks, jump index to the end of the searched sequence
        //  and keep looking
        if (available_blocks < blocks_needed) {
            index += available_blocks;
            continue;
        }

        // If we got here then we have a suitable sequence of blocks.
        // Claim them and return the pointer
        if (debug_output) std.debug.print("Claiming {} blocks for allocation, n = {}\n", .{blocks_needed, n});
        self.markBlocks(index, blocks_needed, true);
        const s = index * self.block_size + add_to_align;
        return self.allocations[s .. s + n].ptr;
    }

    // We failed to find a long-enough sequence of available blocks
    return null;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_size: usize, ra: usize) bool {
    const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
    _=buf_align;
    _=ra;

    std.debug.assert(self.ownsSlice(buf));

    // Same size, do nothing
    if (new_size == buf.len) return true;

    // Is this a shrink request?
    if (new_size < buf.len) {
        return self.shrink(buf, new_size);
    }

    // Find the index of the buffer's end block
    const index = self.getIndex(if (buf.len > 0) &buf[buf.len-1] else @ptrCast(*u8, buf.ptr));

    // How many additional blocks do we need?
    const blocks_needed = common.divideRoundUp(new_size - buf.len, self.block_size);

    // Are enough blocks immediately available after the current blocks to extend?
    var available_blocks = self.countAvailableBlocks(index, blocks_needed);
    if (available_blocks < blocks_needed) return false;

    // Claim the additional block and return the grown slice
    self.markBlocks(index, blocks_needed, true);
    return true;
}

fn shrink(self: *Self, buf: []u8, new_size: usize) bool {
    std.debug.assert(new_size > 0);
    std.debug.assert(buf.len > 0);
    std.debug.assert(buf.len > new_size);

    // Find the current end block index
    const end_index = self.getIndex(&buf[buf.len-1]);
    // and the index of the proposed new end index
    const new_end_index = self.getIndex(&buf[new_size]);

    // Shrinking doesn't free any blocks; succeed but don't change anything
    if (end_index == new_end_index) return true;

    // new_end_index is included in the retained section, but we can free
    //  all blocks from after it up to and including end_index
    self.markBlocks(new_end_index + 1, end_index - new_end_index, false);
    return true;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
    _=buf_align;
    _=ret_addr;

    const start_index = self.getIndex(@ptrCast(*u8, buf.ptr));
    const end_index = self.getIndex(if (buf.len > 0) &buf[buf.len-1] else @ptrCast(*u8, buf.ptr));

    // Add one because we want to include end_index
    self.markBlocks(start_index, end_index - start_index + 1, false);
}

fn getBlock(self: *Self, index: usize) []u8 {
    const s = self.block_size * index;
    return self.allocations[s .. s + self.block_size];
}

fn getIndex(self: *Self, ptr: *u8) usize {
    return (@ptrToInt(ptr) - @ptrToInt(self.allocations.ptr)) / self.block_size;
}

// Returns the number of available blocks starting from `index`.
// Assumes the block at `index` is available.
// Exits early if `up_to` count is reached.
fn countAvailableBlocks(self: *const Self, index: usize, up_to: usize) usize {
    std.debug.assert(index < self.in_use_bitmap.capacity());

    // Ensure we don't try to go past the end of the bitmap
    const max_len = std.math.min(up_to, self.in_use_bitmap.capacity() - index);

    var available_blocks: usize = 1;
    while (available_blocks < max_len) : (available_blocks += 1) {
        // If we find a used block while searching, skip the iterator
        //  forward to after this position and start searching again
        if (self.in_use_bitmap.isSet(index + available_blocks)) {
            break;
        }
    }
    return available_blocks;
}

// Modifies the in_use_bitmap, setting the bits from start up to start+len
//  to `as` (true = in use, false = available).
// Also updates the `first_available_block` field.
fn markBlocks(self: *Self, start: usize, len: usize, as: bool) void {

    const old_first_avail = self.first_available_block;
    defer {
        if (debug_output)
            std.debug.print("Moved first_available_block from {} to {}; start={}, len={}\n",
                            .{ old_first_avail, self.first_available_block, start, len });
    }

    std.debug.assert(start + len < self.in_use_bitmap.capacity());
    var index: usize = 0;
    while (index < len) : (index += 1) {
        std.debug.assert(self.in_use_bitmap.isSet(start + index) != as);

        if (as) {
            self.in_use_bitmap.set(start + index);
        } else {
            self.in_use_bitmap.unset(start + index);
        }
    }

    // Update first_available_block
    if (as and start >= self.first_available_block and self.first_available_block < start + len) {
        // We were marking blocks as claimed and the current first_available_block
        //  was just marked; find a new first block by searching after index
        self.first_available_block = start + len;
        while (self.first_available_block < self.in_use_bitmap.capacity() and
               self.in_use_bitmap.isSet(self.first_available_block)) {
            self.first_available_block += 1;
        }

    } else if (!as and start < self.first_available_block) {
        // We were freeing blocks and start was before first_available_block
        self.first_available_block = start;
    }
}

fn bitmapBytesRequired(n_blocks_desired: usize) usize {
    // Note that DynamicBitSetUnmanaged actually allocates one additional
    //  usize to store allocation size.
    // Unfortunately this means that the accuracy of this function is linked
    //  to implementation details of std.bit_set.DynamicBitSetUnmanaged.
    const words_needed = common.divideRoundUp(n_blocks_desired, @bitSizeOf(usize));
    return words_needed * usize_bytes + usize_bytes;
}

test "BitmapBlockAllocator" {
    try std.testing.expectEqual(@as(usize, 2 * usize_bytes + 2 * 16), Self.bufferSizeRequired(16, 2));
    try std.testing.expectEqual(@as(usize, 1024), Self.bufferSizeRequired(16, 63));
    try std.testing.expectEqual(@as(usize, 4088), Self.bufferSizeRequired(16, 253));

    var buffer: [1024]u8 = undefined;
    var bba = Self.init(&buffer, 16, 63);
    var ally = bba.allocator();
    try std.testing.expectEqual(@as(usize, 4), std.fmt.count("{}", .{1000}));
    const first_alloc = try std.fmt.allocPrint(ally, "{}", .{ 1000 });
    try std.testing.expectEqualStrings("1000", bba.allocations[0..4]);
    try std.testing.expectEqual(@as(usize, 1), bba.first_available_block);
    try std.testing.expectEqual(@as(usize, 1), bba.in_use_bitmap.count());

    //                                      012345678901234567
    const second_alloc = try ally.dupe(u8, "This is seventeen!");
    try std.testing.expectEqualStrings("This is seventeen!", bba.allocations[16..16+18]);
    try std.testing.expectEqual(@as(usize, 3), bba.first_available_block);
    try std.testing.expectEqual(@as(usize, 3), bba.in_use_bitmap.count());

    ally.free(first_alloc);
    try std.testing.expectEqual(@as(usize, 0), bba.first_available_block);
    try std.testing.expectEqual(@as(usize, 2), bba.in_use_bitmap.count());

    ally.free(second_alloc);
    try std.testing.expectEqual(@as(usize, 0), bba.first_available_block);
    try std.testing.expectEqual(@as(usize, 0), bba.in_use_bitmap.count());

    // Ensure alignment works correctly (single block)
    _  = try ally.alignedAlloc(u64, 2, 1);
    try std.testing.expectEqual(@as(usize, 1), bba.first_available_block);
    try std.testing.expectEqual(@as(usize, 1), bba.in_use_bitmap.count());

    var usage = bba.getUsage();
    try std.testing.expectEqual(@as(usize, 1), usage.used_blocks);
    try std.testing.expectEqual(@as(usize, 62), usage.free_blocks);

    bba.freeAll();
}

test "testAll" {
    std.testing.refAllDeclsRecursive(@This());
}
