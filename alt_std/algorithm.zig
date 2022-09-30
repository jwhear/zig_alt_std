//! Implementation of many common algorithms, all on Zig slices.  In a mature
//!  standard library these functions are implemented on something more generic
//!  than slices, i.e. iterators or ranges.  Because Zig hasn't standardized on
//!  interfaces for these concepts the implementations are left as slice-specific.
//!
//! ## Stable/unstable orderings
//! Users should assume that all mutation functions produce unstable orderings
//!  unless the function name promises otherwise.  In many cases the unstable
//!  versions are simply aliases to the stable versions, but more efficient unstable
//!  implementations may be available in the future.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

// There is an issue with recursive functions in stage2 that causes the compiler
//  to overflow with some implementations here.  Setting this to false will
//  cause those tests to not be run.  This bug is not present in stage1.
// https://github.com/ziglang/zig/issues/12973
const has_bug_12973 = @import("builtin").zig_backend == .stage1;


// Internal tooling for testing/verifying complexity
const trackSwaps = false;
var swaps: usize = 0;
fn local_swap(comptime T: type, a: *T, b: *T) void {
    var temp = b.*;
    b.* = a.*;
    a.* = temp;
    swaps += 1;
}
const swap = if (trackSwaps) local_swap else std.mem.swap;


///
pub fn Predicate(comptime T: type) type {
    return fn (T) bool;
}


/// This function operates on the (conceptual) concatenation of `front` and
/// `back`, bringing all the elements of `back` forward so that they occur
///  before the elements of `front`.
///
/// This function detects when `front` overlaps with `back` and does not duplicate
///  elements from the overlap.  This means that it is valid to call when `back`
///  is a slice of `front`, where `front` and `back` overlap in the middle, and
///  where `front` and `back` are completely disjoint.  However, `front[0]`
///  must not be reachable by iterating `back`.
///
/// Relative ordering of elements within both slices is maintained.
///
/// Returns the length of `back`; if front and back are not disjoint this will
///  also be the new index of `front[0]`.
pub fn stableBringToFront(comptime Element: type, front: []Element, back: []Element) usize {
    // This algorithm is expressed most naturally with recursion, however with
    //  long slices it can easily blow out the stack.  Thus it is implemented
    //  here iteratively.

    // mutable slices of front and back; we'll swap elements between them until
    //  one or the other is exhausted
    var front_slice = front;
    var back_slice = back;

    // This outer layer of iteration replaces recursion
    while (front_slice.len > 0 and back_slice.len > 0) {
        // If `back` is already at front then we're done
        if (&back_slice[0] == &front_slice[0]) break;

        // We'll iteratively reduce `back`; save a snapshot here
        var back0 = back_slice;
        var n_swaps: usize = 0;

        // This layer of iteration performs the main job of the algorithm by
        //  swapping front<->back elements as long as it can
        while (front_slice.len > 0 and back_slice.len > 0) {

            // Are we at the overlap point?  For disjoint slices this will never
            //  be true.  When it is true, we update back0 to point here
            if (&front_slice[0] == &back0[0])
                back0 = back_slice;

            swap(Element, &front_slice[0], &back_slice[0]);
            front_slice = front_slice[1..];
            back_slice = back_slice[1..];
            n_swaps += 1;
        }

        // At this point we have three possibilities:
        // 1) Both front_slice and back_slice are exhausted: we're done
        // 2) back_slice is exhausted but there are still items in front_slice:
        //    these need to be moved to maintain the relative ordering of `front`
        // 3) front_slice is exhausted but there are still items in back_slice:
        //    these need to be moved to maintain the relative ordering of `back`
        if (back_slice.len == 0) {
            // Case 1: we're done
            if (front_slice.len == 0) break;

            // Case 2: the front was longer than the back, we need to fix up the
            //  front to maintain relative ordering
            // Loop, effectively `bringToFront(front_slice, back0)`
            back_slice = back0;
        } else {
            std.debug.assert(front_slice.len == 0);
            const len = if (n_swaps < back0.len) n_swaps else back0.len;
            // Case 3: the back was longer than the front
            // Loop, effectively `bringToFront(back0[0..len], back_slice)`
            front_slice = back0[0.. len];
        }
    }

    return back.len;
}

/// This function operates on the (conceptual) concatenation of `front` and
/// `back`, bringing all the elements of `back` forward so that they occur
///  before the elements of `front`.
///
/// This function detects when `front` overlaps with `back` and does not duplicate
///  elements from the overlap.  This means that it is valid to call when `back`
///  is a slice of `front`, where `front` and `back` overlap in the middle, and
///  where `front` and `back` are completely disjoint.  However, `front[0]`
///  must not be reachable by iterating `back`.
///
/// Returns the length of `back`; if front and back are not disjoint this will
///  also be the new index of `front[0]`.
pub const bringToFront = stableBringToFront;

test "bringToFront, minimal" {
    // front:        ↓     ↓
    var items = [_]i8{0,1,2};
    // back:             ↑ ↑
    const partition_index = bringToFront(i8, &items, items[2..]);
    try expectEqual(@as(usize, 1), partition_index);
    try expectEqualSlices(i8, &[_]i8{2,0,1}, &items);
}
test "bringToFront, disjoint" {
    var items1 = [_]i8{0,1,2,3,4};
    var items2 = [_]i8{5,6};
    const partition_index = bringToFront(i8, &items1, &items2);
    try expectEqual(@as(usize, 2), partition_index);
    try expectEqualSlices(i8, &[_]i8{5,6,0,1,2}, &items1);
    try expectEqualSlices(i8, &[_]i8{3,4}, &items2);
}
test "bringToFront, disjoint with gap" {
    var items1 = [_]i8{0,1,2,3,4};
    var items2 = [_]i8{5,6};
    // we'll only slice the first two elements of items1 for front
    const partition_index = bringToFront(i8, items1[0..2], &items2);
    try expectEqual(@as(usize, 2), partition_index);
    try expectEqualSlices(i8, &[_]i8{5,6,2,3,4}, &items1);
    try expectEqualSlices(i8, &[_]i8{0,1}, &items2);
}
test "bringToFront, long tail" {
    // front:        ↓           ↓
    var items = [_]i8{0,1,2,3,4,5};
    // back:             ↑       ↑
    const partition_index = bringToFront(i8, &items, items[2..]);
    try expectEqual(@as(usize, 4), partition_index);
    try expectEqualSlices(i8, &[_]i8{2,3,4,5,0,1}, &items);
}
test "bringToFront, short tail" {
    // front:        ↓             ↓
    var items = [_]i8{0,1,2,3,4,5,6};
    // back:                 ↑     ↑
    const partition_index = bringToFront(i8, &items, items[4..]);
    try expectEqual(@as(usize, 3), partition_index);
    try expectEqualSlices(i8, &[_]i8{4,5,6,0,1,2,3}, &items);
}
test "bringToFront, back in the middle" {
    // front:        ↓             ↓
    var items = [_]i8{0,1,2,3,4,5,6};
    // back:             ↑   ↑
    const partition_index = bringToFront(i8, &items, @as([]i8, items[2..4]));
    try expectEqual(@as(usize, 2), partition_index);
    try expectEqualSlices(i8, &[_]i8{2,3,0,1,4,5,6}, &items);
}
test "bringToFront, partial overlap" {
    // front:        ↓       ↓
    var items = [_]i8{0,1,2,3,4,5,6};
    // back:             ↑         ↑
    const partition_index = bringToFront(i8, items[0..4], @as([]i8, items[2..]));
    try expectEqual(@as(usize, 5), partition_index);
    try expectEqualSlices(i8, &[_]i8{2,3,4,5,6,0,1}, &items);
}
test "bringToFront, worst-case swaps" {
    var items = [_]usize{0}**100;
    for (items) |*item, index|
        item.* = index;

    swaps = 0;
    // bring the very last item to the front
    const partition_index = bringToFront(usize, &items, items[items.len-1..]);
    try expectEqual(@as(usize, 1), partition_index);

    if (trackSwaps)
        std.debug.print("worst-case bring to front took {} swaps on array of length {}\n",
                        .{ swaps, items.len });
}

/// The result of partitioning a slice: two subslices, one for each predicate result.
pub fn Partition(comptime T: type) type {
    return struct {
        ///
        truthy: []T,
        ///
        falsy: []T
    };
}

/// Moves all elements for which predicate returns true to come before all elements
///  for which it returns false.  Relative ordering is maintained within the two groups.
///
/// Returns a Partition describing the truthy and falsy slices.
pub fn stablePartition(comptime T: type, slice: []T, predicate: Predicate(T)) Partition(T) {
    if (comptime has_bug_12973) {
        @compileError("stage2 cannot handle this function; use -fstage1 or see https://github.com/ziglang/zig/issues/12973");
    }

    // Terminal cases
    if (slice.len == 0)
        return .{ .truthy=slice, .falsy=slice};
    if (slice.len == 1) {
        const p = if (predicate(slice[0])) @as(usize, 1) else 0;
        return .{ .truthy=slice[0..p], .falsy=slice[p..] };
    }

    // Recursively partition
    const middle = slice.len / 2;
    const lower = stablePartition(T, slice[0..middle], predicate);
    const upper = stablePartition(T, slice[middle..], predicate);
    // At this point `slice` looks like:
    // -----------------------------------------------------------
    // | lower.truthy | lower.falsy | upper.truthy | upper.falsy |
    // -----------------------------------------------------------
    //
    // We can simply use bringToFront to rotate lower.falsy and upper.truthy,
    //  resulting in:
    // -----------------------------------------------------------
    // | lower.truthy | upper.truthy | lower.falsy | upper.falsy |
    // -----------------------------------------------------------
    //              pivot point here ↑
    _=bringToFront(T, lower.falsy, upper.truthy);

    const pivot = lower.truthy.len + upper.truthy.len;
    return .{ .truthy=slice[0..pivot], .falsy=slice[pivot..] };
}
test "stablePartition" {
    if (comptime !has_bug_12973) {
        const isOdd = struct {
            pub fn f(val: i8) bool {
                return val & 1 == 1;
            }
        }.f;

        var items = [_]i8{0,1,2,3,4,5,6};
        const part = stablePartition(i8, &items, isOdd);
        try expectEqualSlices(i8, &[_]i8{1,3,5}, part.truthy);
        try expectEqualSlices(i8, &[_]i8{0,2,4,6}, part.falsy);
        try expectEqualSlices(i8, &[_]i8{1,3,5,  0,2,4,6}, &items);
    } else {
        std.debug.print("Skipping test for gather; see #12973\n", .{});
    }
}

/// Moves all elements for which predicate returns true to come before all elements
///  for which it returns false.
///
/// Returns a Partition describing the truthy and falsy slices.
pub const partition = stablePartition;

// Enforces that `fun` takes a single argument and returns the type of that argument.
//pub fn Arg0(comptime fun: anytype) type {
//    const Args = std.meta.ArgsTuple(@TypeOf(fun));
//    const fields = std.meta.fields(Args);
//    if (fields.len != 1) {
//        @compileError("Function does not take exactly one argument: "++@TypeOf(fun));
//    }
//    return fields[0].field_type;
//}

/// Inverts function `fun`
pub fn not(comptime Arg: type, comptime fun: fn(Arg) bool) fn(Arg) bool {
    return struct {
        pub fn f(arg: Arg) bool {
            return !fun(arg);
        }
    }.f;
}


/// Moves the content of selection within `slice` to `target`, shifting neighboring
///  elements accordingly.  This function is always stable.
/// `selection_start` and `target` must be valid indices in `slice`.
/// `selection_start` + `selection_len` must be less than or equal to `slice.len`
///
/// Described by Sean Parent
pub fn slide(comptime T: type, slice: []T, selection_start: usize, selection_len: usize, target: usize) []T {

    if (selection_len == 0) return slice[0..0];
    const selection_end = selection_start + selection_len;
    std.debug.assert(target < slice.len);
    std.debug.assert(selection_end < slice.len);

    if (target < selection_start) {
        // a simple bringToFront
        _=bringToFront(T, slice[target..], slice[selection_start .. selection_end]);

    } else if (target > selection_start) {
        var front = slice[selection_start .. selection_end];
        var back = slice[selection_start + selection_len .. target + selection_len];
        _=bringToFront(T, front, back);
    }

    return slice[target .. target + selection_len];
}
test "slide forwards" {
    // selection       ↓   ↓
    var items = [_]i8{0,1,2,3,4,5,6};
    // target                  ↑
    const selection_at_target = slide(i8, &items, 1, 2, 5);
    try expectEqualSlices(i8, &[_]i8{1,2}, selection_at_target);
    try expectEqualSlices(i8, &[_]i8{0,3,4,5,6,1,2}, &items);
}
test "slide backwards" {
    // selection             ↓   ↓
    var items = [_]i8{0,1,2,3,4,5,6};
    // target          ↑
    const selection_at_target = slide(i8, &items, 4, 2, 1);
    try expectEqualSlices(i8, &[_]i8{4,5}, selection_at_target);
    try expectEqualSlices(i8, &[_]i8{0,4,5,1,2,3,6}, &items);
}
test "slide to first" {
    // selection             ↓   ↓
    var items = [_]i8{0,1,2,3,4,5,6};
    // target        ↑
    const selection_at_target = slide(i8, &items, 4, 2, 0);
    try expectEqualSlices(i8, &[_]i8{4,5}, selection_at_target);
    try expectEqualSlices(i8, &[_]i8{4,5,0,1,2,3,6}, &items);
}

///
pub fn slideToStart(comptime T: type, slice: []T, selection_start: usize, selection_len: usize) []T {
    return slide(T, slice, selection_start, selection_len, 0);
}

///
pub fn slideToEnd(comptime T: type, slice: []T, selection_start: usize, selection_len: usize) []T {
    std.debug.assert(selection_len <= slice.len);
    return slide(T, slice, selection_start, selection_len, slice.len - selection_len);
}

/// Gathers all elements in `slice` for which `predicate` is true together and
///  places them "around" `target`.  Specifically, all predicated elements which
///  are before `target` will be placed immediately before `target`, while all
///  elements after `target` will be placed immediately after `target`.
/// This function is always stable.
///
/// Returns the slice representing the truthy elements.
pub fn gather(comptime T: type, slice: []T, comptime predicate: Predicate(T), target: usize) []T {
    if (comptime has_bug_12973) {
        @compileError("stage2 cannot handle this function; use -fstage1 or see https://github.com/ziglang/zig/issues/12973");
    }

    const lower = stablePartition(T, slice[0..target], not(T, predicate));
    const upper = stablePartition(T, slice[target..], predicate);
    return slice[target - lower.falsy.len .. target + upper.truthy.len];
}
test "gather" {
    if (comptime !has_bug_12973) {
        const isOdd = struct {
            pub fn f(val: i8) bool {
                return val & 1 == 1;
            }
        }.f;
        // target               ↓
        var items = [_]i8{0,1,2,3,4,5,6};
        const truthy = gather(i8, &items, isOdd, 3);
        try expectEqualSlices(i8, &[_]i8{1,3,5}, truthy);
        try expectEqualSlices(i8, &[_]i8{0,2, 1,3,5, 4,6}, &items);
    } else {
        std.debug.print("Skipping test for gather; see #12973\n", .{});
    }
}

/// Moves all values less than `slice[pivot]` to the left of `pivot` and returns
///  an updated pivot.
///
/// Note that this does not mean that slice[0..pivot] is sorted, only that all
///  elements in that range are less than slice[pivot].
pub fn pivotPartition(
    comptime T: type,
    slice: []T,
    pivot: usize,
    context: anytype,
    comptime lessThan: fn (context: @TypeOf(context), lhs: T, rhs: T) bool
) usize {
    std.debug.assert(slice.len > 0);

    const pivot_value = slice[pivot];
    // Assume that all values are less than pivot by moving it to the far right
    swap(T, &slice[pivot], &slice[slice.len-1]);
    var write_index: usize = 0;

    // Move all values in slice which are less than pivot_value to the left
    for (slice) |*val| {
        if (lessThan(context, val.*, pivot_value)) {
            swap(T, &slice[write_index], val);
            write_index += 1;
        }
    }

    // Move pivot to its final place
    swap(T, &slice[slice.len-1], &slice[write_index] );
 
    return write_index;
}
test "pivotPartition" {
    // pivot          ↓
    var items = [_]i8{3,1,2,4,4,1,1};
    // sorted:        1,1,1,2,3,4,4
    const lessThan = comptime std.sort.asc(i8);
    const pivot = pivotPartition(i8, &items, 0, {}, lessThan);
    try expectEqual(@as(usize, 4), pivot);
    try expectEqualSlices(i8, &[_]i8{1,1,2,1,3,4,4}, &items);
}
test "pivotPartition, sorted" {
    // pivot                ↓
    var items = [_]i8{1,1,1,2,3,4,4};
    const lessThan = comptime std.sort.asc(i8);
    const pivot = pivotPartition(i8, &items, 3, {}, lessThan);
    try expectEqual(@as(usize, 3), pivot);
    try expectEqualSlices(i8, &[_]i8{1,1,1,2,3,4,4}, &items);
}
test "pivotPartition, far left" {
    // pivot          ↓
    var items = [_]i8{1,3,2,4,4,1,1};
    // sorted:        1,1,1,2,3,4,4
    const lessThan = comptime std.sort.asc(i8);
    const pivot = pivotPartition(i8, &items, 0, {}, lessThan);
    try expectEqual(@as(usize, 0), pivot);
    try expectEqualSlices(i8, &[_]i8{1,3,2,4,4,1,1}, &items);
}
test "pivotPartition, far right" {
    // pivot                      ↓
    var items = [_]i8{1,3,2,4,4,1,1};
    // sorted:        1,1,1,2,3,4,4
    const lessThan = comptime std.sort.asc(i8);
    const pivot = pivotPartition(i8, &items, items.len-1, {}, lessThan);
    try expectEqual(@as(usize, 0), pivot);
    try expectEqualSlices(i8, &[_]i8{1,3,2,4,4,1,1}, &items);
}

/// Returns the i'th element of `slice` as if `slice` was sorted according to
///  `lessThan`.  Mutates `slice` into an undefined ordering.
///
/// Slice must not be empty and `i` must be less than `slice.len`.
///
/// Implementation is Hoare's selection algorithm (aka quickselect).
/// See: https://en.wikipedia.org/wiki/Quickselect
///
/// Time complexity is O(n) on average, particularly for large n.
pub fn ith(
    comptime T: type,
    slice: []T,
    i: usize,
    context: anytype,
    comptime lessThan: fn (context: @TypeOf(context), lhs: T, rhs: T) bool
) T {
    std.debug.assert(i < slice.len);
    std.debug.assert(slice.len > 0);

    // mutable slice: we will narrow in on the ith element by reducing this slice
    var selection = slice;
    // i relative to the current selection
    var relative_i = i;

    // Reduce selection until it is len==1
    while (selection.len > 1) {
        // Pick a pivot from middle of selection
        //TODO there are better pivot selections (random/median of 3)
        var pivot = selection.len / 2;

        // Move anything smaller than selection[pivot] to the left of pivot and
        //  return updated value of pivot
        pivot = pivotPartition(T, selection, pivot, context, lessThan);

        // If pivot is the ith element, then we're done
        if (pivot == relative_i) return selection[relative_i];

        // Otherwise we can narrow our selection and go around again
        if (relative_i < pivot) {
            // ith element is in the left "half"
            selection = selection[0..pivot];
        } else {
            // ith element is in the right "half"
            selection = selection[pivot+1..];
            relative_i -= pivot + 1;
        }
    }
    return selection[0];
}
test "ith" {
    var items    = [_]i8{3,1,2,4,4,1,1};
    const sorted = [_]i8{1,1,1,2,3,4,4};
    const lessThan = comptime std.sort.asc(i8);
    for (sorted) |expected, i| {
        try expectEqual(expected, ith(i8, &items, i, {}, lessThan));
    }
}

/// Returns true if predicate evaluates to true for any element in slice.
pub fn any(comptime T: type, slice: []const T, predicate: Predicate(T)) bool {
    return findIf(T, slice, predicate) != null;
}
test "any" {
    const isOdd = struct {
        pub fn f(val: i8) bool {
            return val & 1 == 1;
        }
    }.f;

    var items = [_]i8{1,3,5,2,4};
    try expectEqual(true, any(i8, &items, isOdd));
    try expectEqual(true, any(i8, &items, not(i8, isOdd)));
    try expectEqual(false, any(i8, items[0..3], not(i8, isOdd)));
}

/// Evalutes `predicate` on each element of `slice` and returns true only if
///  `predicate(element)` returns true for every element.
pub fn all(comptime T: type, slice: []const T, predicate: Predicate(T)) bool {
    //NOTE this could also be implemented in terms of `findIf` using `not`, but
    // that would force `predicate` to be comptime.
    for (slice) |element| {
        if (!predicate(element)) return false;
    }
    return true;
}
test "all" {
    const isOdd = struct {
        pub fn f(val: i8) bool {
            return val & 1 == 1;
        }
    }.f;

    var items = [_]i8{1,3,5,2,4};
    try expectEqual(false, all(i8, &items, isOdd));
    try expectEqual(true, all(i8, items[0..3], isOdd));
}

/// Returns the number of elements in `slice` for which `predicate` is true.
pub fn countIf(comptime T: type, slice: []const T, predicate: Predicate(T)) usize {
    var count: usize = 0;
    for (slice) |element| {
        if (predicate(element))
            count += 1;
    }
    return count;
}
test "countIf" {
    const isOdd = struct {
        pub fn f(val: i8) bool {
            return val & 1 == 1;
        }
    }.f;

    var items = [_]i8{1,3,5,2,4};
    try expectEqual(@as(usize, 3), countIf(i8, &items, isOdd));
    try expectEqual(@as(usize, 2), countIf(i8, &items, not(i8, isOdd)));
}

/// Returns the index of the first element in `slice` for which `predicate` is
///  true or null if no elements satisfy the predicate.
pub fn findIf(comptime T: type, slice: []const T, predicate: Predicate(T)) ?usize {
    for (slice) |element, index| {
        if (predicate(element)) return index;
    }
    return null;
}
test "findIf" {
    const isOdd = struct {
        pub fn f(val: i8) bool {
            return val & 1 == 1;
        }
    }.f;

    var items = [_]i8{1,3,5,2,4};
    try expectEqual(@as(?usize, 0), findIf(i8, &items, isOdd));
    try expectEqual(@as(?usize, 3), findIf(i8, &items, not(i8, isOdd)));
    try expectEqual(@as(?usize, null), findIf(i8, items[0..3], not(i8, isOdd)));
}

/// Returns a slice of `first` that represents the longest prefix shared with `second`.
pub fn commonPrefix(comptime T: type, first: []const T, second: []const T) []const T {
    const max_len = std.math.min(first.len, second.len);
    var len: usize = 0;
    while (len < max_len and first[len] == second[len]) {
        len += 1;
    }
    return first[0..len];
}
test "commonPrefix" {
    const a = [_]i8{0,1,2,3};
    const b = [_]i8{0,1,7,8};
    const c = [_]i8{0,1,2,3,4,5};
    const d = [_]i8{4,5};
    try expectEqualSlices(i8, &a, commonPrefix(i8, &a, &a));
    try expectEqualSlices(i8, &[_]i8{0,1}, commonPrefix(i8, &a, &b));
    try expectEqualSlices(i8, &a, commonPrefix(i8, &a, &c));
    try expectEqualSlices(i8, &a, commonPrefix(i8, &c, &a));
    try expectEqualSlices(i8, &[_]i8{}, commonPrefix(i8, &a, &d));
}

///
pub const OptionalIndexPair = struct {
    ///
    first: ?usize,
    ///
    second: ?usize,
};

/// Returns a pair of optional indexes identifying the first element where
///  `first` and `second` differ.  If one slice is a complete prefix of the other
///  then its index will be null (there is no valid index where it differs).
///  If the slices are identical then both indexes will be null.
pub fn mismatch(comptime T: type, first: []const T, second: []const T) OptionalIndexPair {
    const prefix = commonPrefix(T, first, second);
    return OptionalIndexPair{
        .first=if (prefix.len == first.len) null else prefix.len,
        .second=if (prefix.len == second.len) null else prefix.len,
    };
}
test "mismatch" {
    const a = [_]i8{0,1,2,3};
    const b = [_]i8{0,1,7,8};
    const c = [_]i8{0,1,2,3,4,5};
    const d = [_]i8{4,5};
    try expectEqual(OptionalIndexPair{ .first=null, .second=null}, mismatch(i8, &a, &a));
    try expectEqual(OptionalIndexPair{ .first=2, .second=2},       mismatch(i8, &a, &b));
    try expectEqual(OptionalIndexPair{ .first=null, .second=4},    mismatch(i8, &a, &c));
    try expectEqual(OptionalIndexPair{ .first=0, .second=0},       mismatch(i8, &a, &d));
}

/// Returns true if every instance of `open` is balanced by a following `close`,
///  up to `max_nesting` levels deep.  As an example, this can verify that every
///  opening parenthesis has a matching closing parenthesis.
pub fn balanced(comptime T: type, slice: []const T, open: T, close: T, max_nesting: usize) bool {
    var open_count: usize = 0;
    for (slice) |element| {
        if (element == open) {
            // incrementing would exceed max_nesting, fail
            if (open_count == max_nesting) return false;
            open_count += 1;

        } else if (element == close) {
            // decrementing would underflow, fail because we have a close
            //  without an open
            if (open_count == 0) return false;
            open_count -= 1;
        }
    }
    return open_count == 0;
}
test "balanced" {
    try expectEqual(true, balanced(u8, "(a(b))", '(', ')', 100));
    try expectEqual(false, balanced(u8, "(a(b)", '(', ')', 100));
    try expectEqual(false, balanced(u8, "a(b))", '(', ')', 100));
    try expectEqual(false, balanced(u8, "(a(b))", '(', ')', 1));
}

