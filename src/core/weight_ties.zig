const std = @import("std");

pub const TensorConflictStats = struct {
    n_conflict: usize,
    n_total: usize,
    conflict_pct: f64,
};

pub fn computeConflictStats(task_a: []const f32, task_b: []const f32, threshold: f32) TensorConflictStats {
    var n_conflict: usize = 0;
    var n_total: usize = 0;
    var i: usize = 0;
    while (i < task_a.len) : (i += 1) {
        const va = task_a[i];
        const vb = task_b[i];
        if (@abs(va) < threshold or @abs(vb) < threshold) continue;
        n_total += 1;
        const sign_a = va > 0;
        const sign_b = vb > 0;
        if (sign_a != sign_b) n_conflict += 1;
    }
    const pct: f64 = if (n_total > 0)
        @as(f64, @floatFromInt(n_conflict)) / @as(f64, @floatFromInt(n_total)) * 100.0
    else
        0.0;
    return .{ .n_conflict = n_conflict, .n_total = n_total, .conflict_pct = pct };
}

fn trimByMagnitude(allocator: std.mem.Allocator, task_vector: []const f32, density: f64) ![]f32 {
    const out = try allocator.dupe(f32, task_vector);
    if (task_vector.len == 0) return out;

    const keep_count: usize = @intFromFloat(@as(f64, @floatFromInt(task_vector.len)) * density);
    if (keep_count >= task_vector.len) return out;
    if (keep_count == 0) {
        @memset(out, 0);
        return out;
    }

    var indices = try allocator.alloc(usize, task_vector.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;

    std.mem.sort(usize, indices, task_vector, struct {
        fn lt(ctx: []const f32, a: usize, b: usize) bool {
            return @abs(ctx[a]) > @abs(ctx[b]);
        }
    }.lt);

    var keep_mask = try allocator.alloc(bool, task_vector.len);
    defer allocator.free(keep_mask);
    @memset(keep_mask, false);
    for (indices[0..keep_count]) |idx| keep_mask[idx] = true;

    for (out, 0..) |*v, i| {
        if (!keep_mask[i]) v.* = 0;
    }

    return out;
}

pub fn tiesMergeTensor(
    allocator: std.mem.Allocator,
    base: []const f32,
    task_vectors: []const []const f32,
    density: f64,
    lambda: f64,
) ![]f32 {
    const n = base.len;
    var trimmed = try allocator.alloc([]f32, task_vectors.len);
    defer {
        for (trimmed) |t| allocator.free(t);
        allocator.free(trimmed);
    }
    for (task_vectors, 0..) |tv, i| {
        trimmed[i] = try trimByMagnitude(allocator, tv, density);
    }

    var elected_sign = try allocator.alloc(f32, n);
    defer allocator.free(elected_sign);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var pos_mass: f64 = 0;
        var neg_mass: f64 = 0;
        for (trimmed) |t| {
            const v = t[i];
            if (v > 0) pos_mass += v else if (v < 0) neg_mass += -v;
        }
        elected_sign[i] = if (pos_mass >= neg_mass) 1.0 else -1.0;
    }

    var merged_task = try allocator.alloc(f32, n);
    defer allocator.free(merged_task);
    i = 0;
    while (i < n) : (i += 1) {
        var sum: f64 = 0;
        var count: usize = 0;
        for (trimmed) |t| {
            const v = t[i];
            if (v == 0) continue;
            const same_sign = (v > 0) == (elected_sign[i] > 0);
            if (same_sign) {
                sum += v;
                count += 1;
            }
        }
        const avg: f64 = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0.0;
        merged_task[i] = @floatCast(avg * lambda);
    }

    var merged = try allocator.alloc(f32, n);
    i = 0;
    while (i < n) : (i += 1) merged[i] = base[i] + merged_task[i];

    return merged;
}

pub fn computeTaskVector(allocator: std.mem.Allocator, base: []const f32, finetuned: []const f32) ![]f32 {
    const n = @min(base.len, finetuned.len);
    var out = try allocator.alloc(f32, n);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = finetuned[i] - base[i];
    return out;
}
