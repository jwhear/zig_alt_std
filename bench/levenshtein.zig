const std = @import("std");
const alt_std = @import("alt_std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const ally = gpa.allocator();

    var corpus = std.ArrayList([]const u8).init(ally);
    defer corpus.deinit();

    // Generate random strings
    var rng = std.rand.DefaultPrng.init(0);
    const rand = rng.random();
    while (corpus.items.len < 1_000) {
        // Allocate up to 64 bytes
        var str = try ally.alloc(u8, rand.uintAtMost(u64, 64));

        // Fill with random bytes; for debugging purposes limit to capital ASCII
        for (str) |*b| {
            b.* = rand.uintAtMost(u8, 24) + 65;
        }
        try corpus.append(str);
    }
    defer {
        for (corpus.items) |str| {
            ally.free(str);
        }
    }

    // To prove that we have apples-to-apples and aren't accidentally getting
    //  allocation overhead we'll use a FailingAllocator so that the benchmark
    //  will explode if one of the distance functions actually tries to allocate
    var fa = std.testing.FailingAllocator.init(ally, 0);
    const dist_ally = fa.allocator();

    // Track the cumulative time for each method
    var times = [_]u64{0, 0, 0};
    const methods = [_][]const u8{
        "naive",
        "fast64",
        "low mem",
    };
    var timer = try std.time.Timer.start();
    var comparisons: usize = 0;

    // Conduct multiple rounds to smooth out random spikes
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        std.debug.print("Round {}\r", .{round});

        // Compare every string against every other string
        for (corpus.items) |a| {
            for (corpus.items) |b| {
                timer.reset();
                const method0_result = try alt_std.levenshtein.distanceNaive(dist_ally, a, b, .{});
                times[0] += timer.read();

                timer.reset();
                // No allocator needed and cannot fail, yay!
                const method1_result = alt_std.levenshtein.distance64(a, b);
                times[1] += timer.read();

                timer.reset();
                const method2_result = try alt_std.levenshtein.distanceAlloc(dist_ally, a, b, .{});
                times[2] += timer.read();

                comparisons += 1;

                // All methods should produce the same results
                try std.testing.expectEqual(method0_result, method1_result);
                try std.testing.expectEqual(method1_result, method2_result);
            }
        }
    }

    // Use the naive method as our timing baseline
    const baseline = @intToFloat(f64, times[0]);
    for (times) |t, idx| {
        std.debug.print("Method {s: >10}: {: >14} ns total, {: >6} ns/op, {d: >6.2}x\n", .{
            methods[idx], t, t/comparisons, baseline/@intToFloat(f64, t)
        });
    }
}
