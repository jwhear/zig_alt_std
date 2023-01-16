//! Important: the functions in this module operate on bytes and are
//!  **not** Unicode-aware, although they are safe to use on strings of any
//!  encoding.  In practice this means that two strings which appear the same
//!  but have distinct encodings will have a non-zero edit distance.
//!  It is recommended that you normalize and canonicalize your inputs.
const std = @import("std");

pub const EditCosts = struct {
    insert: u64 = 1,
    delete: u64 = 1,
    update: u64 = 1,
};

/// Computes the Levenshtein distance of two strings, `a` and `b`.
/// If the caller can guarantee that both `a` and `b` are 64 bytes or less in
///  length, see `distance64` for a implementation that does not allocate and
///  cannot fail.
pub fn distance(allocator: std.mem.Allocator, a: []const u8, b: []const u8,
                           edit_costs: EditCosts) error{OutOfMemory}!u64 {
    return if (a.len <= 64 and b.len <= 64 and edit_costs.insert == 1 and
               edit_costs.delete == 1 and edit_costs.update == 1)
                distance64(a, b)
           else distanceAlloc(allocator, a, b, edit_costs);
}

/// Naive implementation of the Wagner-Fischer algorithm, based on:
///  https://en.wikipedia.org/wiki/Wagner%E2%80%93Fischer_algorithm#Calculating_distance
/// This implementation is provided as a reference; real code should use `distance`.
pub fn distanceNaive(
    allocator: std.mem.Allocator,
    a: []const u8, b: []const u8,
    edit_costs: EditCosts
) !u64 {
    const m = a.len + 1;
    const n = b.len + 1;

    // If both strings are <= 64 bytes long, no heap allocations
    var matrix_buf: [65 * 65]u64 = undefined;
    const needs_alloc = m * n > matrix_buf.len;
    var matrix: []u64 = if (needs_alloc) try allocator.alloc(u64, m * n) else matrix_buf[0..m * n];
    defer if (needs_alloc) allocator.free(matrix);
    std.mem.set(u64, matrix[0..m], 0);

    // Source prefixes can be transformed into empty string by dropping all chars
    var i: usize = 1;
    while (i < m) : (i += 1) {
        matrix[i] = i * edit_costs.delete;
    }

    // Target prefixes can be reached from empty source prefix by inserting every char
    var j: usize = 1;
    while (j < n) : (j += 1) {
        matrix[j * m] = j * edit_costs.insert;
    }

    // Fill the matrix
    j = 1;
    while (j < n) : (j += 1) {
        i = 1;
        while (i < m) : (i += 1) {
            // If the two strings have the same character at this point, we can
            //  "substitute" for free.
            const c_update: u64 = if (a[i-1] == b[j-1]) 0 else edit_costs.update;

            // Select the cheapest path from the previous state
            matrix[j * m + i] = std.math.min(
                matrix[j * m + (i-1)] + edit_costs.delete,
                std.math.min(
                    matrix[(j-1) * m + i] + edit_costs.insert,
                    matrix[(j-1) * m + (i-1)] + c_update
                )
            );
        }
    }

    // The minimal distance is stored in the final diagonal
    return matrix[matrix.len-1];
}

/// Computes the Levenshtein distance for two strings.  The longest string must
///  be no longer than 64 bytes.  This implementation does not allocate and cannot
///  fail barring an assert on the length of the strings.
/// Caller is responsible for enforcing that `a.len <= 64 and b.len <= 64`.
/// This implementation does not support custom edit costs; all costs are 1.
pub fn distance64(a: []const u8, b: []const u8) u64 {
    // This implementation is based on the following paper:
    //   Myers, Gene. (1970). A Fast Bit-Vector Algorithm for Approximate String Matching Based on Dynamic Programming. Journal of the ACM. 46. 10.1145/316542.316550.
    //
    // The algorithm is extremely cool but quite dense--as a result, we do not
    //  attempt to exhaustively comment here; if you want to understand how this
    //  works reading the paper is your best bet.
    const short = if (a.len < b.len) a else b;
    const long = if (a.len < b.len) b else a;
    std.debug.assert(long.len <= 64);

    // Early out if one of the strings is empty
    if (short.len == 0) {
        return long.len;
    }

    // Alphabet preprocessing step.
    // Example, if `short` is "dog":
    //  peq['d'] = 0b101; // 'd' occurs at first and third position
    //  peq['o'] = 0b010; // '0' occurs at the second position
    var peq: [256]u64 = [_]u64{0} ** 256;
	var score: u64 = @intCast(u64, long.len);
	for (long) |c, idx| {
		peq[c] |= @as(u64, 1) << @intCast(u6, idx);
	}

	// The last bit OR'd in
	// In the paper this is the term `10^(m-1)`
	const last_set = @as(u64, 1) << @intCast(u6, score - 1);
	var pv = ~@as(u64, 0); // all 1s to start
	var mv = @as(u64, 0);  // all 0s to start

	for (short) |c| {
    	// The positions of this character in `long`
		var eq = peq[c];

        // If c doesn't appear in `long`, then eq=0 and xv==mv
		var xv = eq | mv;
		const xh = (((eq & pv) +% pv) ^ pv) | eq;

        // Add to `mv` all the bits that aren't in either eq or pv
		var ph = mv | ~(xh | pv);
		const mh = pv & xh;

		if ((ph & last_set) != 0) {
			score += 1;
		}

		if ((mh & last_set) != 0) {
			score -= 1;
		}
		// Shift the bits up, filling with ones
		ph = (ph << 1) | 1;
		pv = (mh << 1) | ~(xv | ph);
		mv = ph & xv;
	}
	return score;
}
test "distance64" {
    const dist = distance64;
    const ee = std.testing.expectEqual;
    try ee(@as(u64, 0), dist("aabb", "aabb"));
    try ee(@as(u64, 1), dist("aabb", "acbb"));
    try ee(@as(u64, 3), dist("", "dog"));
    try ee(@as(u64, 3), dist("dog", ""));
    try ee(@as(u64, 1), dist("dog", "dig"));
    try ee(@as(u64, 1), dist("dog", "do"));
    try ee(@as(u64, 1), dist("d", "do"));
    try ee(@as(u64, 26), dist("abcdefghijklmnopqrstuvwxyz", ""));
    try ee(@as(u64, 52), dist("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz", ""));
    try ee(@as(u64, 50), dist("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    try ee(@as(u64, 2), dist("eleven", "even"));
    try ee(@as(u64, 2), dist("abab", "aabb"));
}

/// Computes the Levenshtein distance for two strings.  This implementation may
///  allocate and can fail only if allocation fails.
pub fn distanceAlloc(
    allocator: std.mem.Allocator,
    a: []const u8, b: []const u8,
    edit_costs: EditCosts
) error{OutOfMemory}!u64 {
    // Ported from the D standard library:
    //  https://github.com/dlang/phobos/blob/71371234e768a3ce14d9d53fd6725938abd51238/std/algorithm/comparison.d#L1407
    // This implementation doesn't store the entire matrix, only last/current row,
    //  resulting in significantly lower memory usage and modest performance uplift
    //  over the naive version, generally ~1.3x faster.
    //
    // Original author: Andrei Alexandrescu
    // Original license:
    //    Boost Software License - Version 1.0 - August 17th, 2003
    //
    //    Permission is hereby granted, free of charge, to any person or organization
    //    obtaining a copy of the software and accompanying documentation covered by
    //    this license (the "Software") to use, reproduce, display, distribute,
    //    execute, and transmit the Software, and to prepare derivative works of the
    //    Software, and to permit third-parties to whom the Software is furnished to
    //    do so, all subject to the following:
    //
    //    The copyright notices in the Software and this entire statement, including
    //    the above license grant, this restriction and the following disclaimer,
    //    must be included in all copies of the Software, in whole or in part, and
    //    all derivative works of the Software, unless such copies or derivative
    //    works are solely in the form of machine-executable object code generated by
    //    a source language processor.
    //
    //    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    //    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    //    FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
    //    SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
    //    FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
    //    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    //    DEALINGS IN THE SOFTWARE.
    const short = if (a.len < b.len) a else b;
    const long = if (a.len < b.len) b else a;
    std.debug.assert(long.len <= 64);

    // Early out if one of the strings is empty
    if (short.len == 0) {
        return long.len;
    }

    // If the strings are 64 bytes or less, no allocations needed
    var matrix_buf: [65]u64 = undefined;
    const m = short.len + 1;
    const needs_alloc = m > matrix_buf.len;
    // actually just the most recent row of the naive matrix
    var matrix: []u64 = if (needs_alloc) try allocator.alloc(u64, m) else matrix_buf[0..m];
    defer if (needs_alloc) allocator.free(matrix);
    std.mem.set(u64, matrix, 0);

    // Initialize the row
    var y: usize = 1;
    while (y < m) : (y += 1) {
        matrix[y] = y;
    }

    // matrix[x-1, y-1]
    var last_diag: u64 = 0;
    var old_diag: u64 = 0;
    var x: usize = 1;

    // Conceptually, this is filling the matrix.  In practice, we're updating the
    //  current row in place.
    while (x < long.len + 1) : (x += 1) {
        var short_i: usize = 0;
        matrix[0] = x;
        last_diag = x - 1;

        y = 1;
        while (y < m) : (y += 1) {
            old_diag = matrix[y];
            const c_update = last_diag + if (short[short_i] == long[x-1])
                                             @as(u64, 0)
                                         else edit_costs.update;
            short_i += 1;
            const c_insert = matrix[y - 1] + edit_costs.insert;
            const c_delete = matrix[y] + edit_costs.delete;
            matrix[y] = std.math.min(
                c_update,
                std.math.min( c_insert, c_delete )
            );
            last_diag = old_diag;
        }
    }
    return matrix[short.len];
}
