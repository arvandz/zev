const std = @import("std");
const weight_diff = @import("weight_diff.zig");
const weight_ties = @import("weight_ties.zig");

pub const MergeStrategy = enum { average, weighted, slerp, ties };

pub const TensorMergeStatus = enum { merged, passthrough_a, passthrough_b, shape_conflict, dtype_conflict };

pub const TensorMergeResult = struct {
    name: []const u8,
    status: TensorMergeStatus,
    shape: []usize,
    dtype: weight_diff.DType,
    conflict_pct: ?f64 = null,
};

pub const MergeReport = struct {
    results: []TensorMergeResult,
    n_merged: usize,
    n_passthrough: usize,
    n_conflict: usize,
    overall_conflict_pct: ?f64 = null,

    pub fn deinit(self: *MergeReport, allocator: std.mem.Allocator) void {
        for (self.results) |r| {
            allocator.free(r.name);
            allocator.free(r.shape);
        }
        allocator.free(self.results);
    }
};

fn f16BitsToF32(bits: u16) f32 {
    const sign: u32 = @as(u32, bits >> 15) << 31;
    const exp: u32 = (bits >> 10) & 0x1F;
    const mant: u32 = bits & 0x3FF;
    if (exp == 0) {
        if (mant == 0) return @bitCast(sign);
        var e: i32 = -14;
        var m = mant;
        while ((m & 0x400) == 0) {
            m <<= 1;
            e -= 1;
        }
        m &= 0x3FF;
        const out_exp: u32 = @intCast(e + 127);
        return @bitCast(sign | (out_exp << 23) | (m << 13));
    }
    if (exp == 31) {
        return @bitCast(sign | 0x7F800000 | (mant << 13));
    }
    const out_exp: u32 = exp - 15 + 127;
    return @bitCast(sign | (out_exp << 23) | (mant << 13));
}

fn bf16BitsToF32(bits: u16) f32 {
    const wide: u32 = @as(u32, bits) << 16;
    return @bitCast(wide);
}

fn f32ToF16Bits(val: f32) u16 {
    const bits: u32 = @bitCast(val);
    const sign: u16 = @intCast((bits >> 16) & 0x8000);
    const exp_i: i32 = @as(i32, @intCast((bits >> 23) & 0xFF)) - 127 + 15;
    const mant: u32 = bits & 0x7FFFFF;
    if (((bits >> 23) & 0xFF) == 0xFF) {
        const half_mant: u16 = if (mant != 0) 0x200 else 0;
        return sign | 0x7C00 | half_mant;
    }
    if (exp_i >= 31) return sign | 0x7C00;
    if (exp_i <= 0) {
        if (exp_i < -10) return sign;
        const shift: u5 = @intCast(14 - exp_i);
        const m: u32 = (mant | 0x800000) >> shift;
        return sign | @as(u16, @intCast(m));
    }
    const half_mant: u16 = @intCast(mant >> 13);
    const half_exp: u16 = @intCast(exp_i);
    return sign | (half_exp << 10) | half_mant;
}

fn f32ToBf16Bits(val: f32) u16 {
    const bits: u32 = @bitCast(val);
    const rounded = bits +% 0x8000;
    return @intCast((rounded >> 16) & 0xFFFF);
}

fn decodeToF32(allocator: std.mem.Allocator, dtype: weight_diff.DType, raw: []const u8) ![]f32 {
    return switch (dtype) {
        .f32 => blk: {
            const n = raw.len / 4;
            var out = try allocator.alloc(f32, n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const bits = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
                out[i] = @bitCast(bits);
            }
            break :blk out;
        },
        .f16 => blk: {
            const n = raw.len / 2;
            var out = try allocator.alloc(f32, n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const bits = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
                out[i] = f16BitsToF32(bits);
            }
            break :blk out;
        },
        .bf16 => blk: {
            const n = raw.len / 2;
            var out = try allocator.alloc(f32, n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const bits = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
                out[i] = bf16BitsToF32(bits);
            }
            break :blk out;
        },
        else => error.UnsupportedDtype,
    };
}

fn encodeFromF32(allocator: std.mem.Allocator, dtype: weight_diff.DType, values: []const f32) ![]u8 {
    return switch (dtype) {
        .f32 => blk: {
            var out = try allocator.alloc(u8, values.len * 4);
            var i: usize = 0;
            while (i < values.len) : (i += 1) {
                const bits: u32 = @bitCast(values[i]);
                std.mem.writeInt(u32, out[i * 4 ..][0..4], bits, .little);
            }
            break :blk out;
        },
        .f16 => blk: {
            var out = try allocator.alloc(u8, values.len * 2);
            var i: usize = 0;
            while (i < values.len) : (i += 1) {
                std.mem.writeInt(u16, out[i * 2 ..][0..2], f32ToF16Bits(values[i]), .little);
            }
            break :blk out;
        },
        .bf16 => blk: {
            var out = try allocator.alloc(u8, values.len * 2);
            var i: usize = 0;
            while (i < values.len) : (i += 1) {
                std.mem.writeInt(u16, out[i * 2 ..][0..2], f32ToBf16Bits(values[i]), .little);
            }
            break :blk out;
        },
        else => error.UnsupportedDtype,
    };
}

fn shapeEqual(a: []usize, b: []usize) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn mergeValues(allocator: std.mem.Allocator, a: []const f32, b: []const f32, strategy: MergeStrategy, alpha: f64) ![]f32 {
    var out = try allocator.alloc(f32, a.len);

    switch (strategy) {
        .average => {
            var i: usize = 0;
            while (i < a.len) : (i += 1) out[i] = (a[i] + b[i]) * 0.5;
        },
        .weighted => {
            const w_a: f32 = @floatCast(alpha);
            const w_b: f32 = @floatCast(1.0 - alpha);
            var i: usize = 0;
            while (i < a.len) : (i += 1) out[i] = a[i] * w_a + b[i] * w_b;
        },
        .slerp => {
            var dot: f64 = 0;
            var na: f64 = 0;
            var nb: f64 = 0;
            var i: usize = 0;
            while (i < a.len) : (i += 1) {
                const fa: f64 = a[i];
                const fb: f64 = b[i];
                dot += fa * fb;
                na += fa * fa;
                nb += fb * fb;
            }
            const norm_a = @sqrt(na);
            const norm_b = @sqrt(nb);
            const denom = norm_a * norm_b;
            const cos_theta = if (denom > 1e-12) std.math.clamp(dot / denom, -1.0, 1.0) else 1.0;
            const theta = std.math.acos(cos_theta);
            const sin_theta = @sin(theta);

            if (sin_theta < 1e-6 or denom < 1e-12) {
                const w_a: f32 = @floatCast(1.0 - alpha);
                const w_b: f32 = @floatCast(alpha);
                i = 0;
                while (i < a.len) : (i += 1) out[i] = a[i] * w_a + b[i] * w_b;
            } else {
                const coef_a: f32 = @floatCast(@sin((1.0 - alpha) * theta) / sin_theta);
                const coef_b: f32 = @floatCast(@sin(alpha * theta) / sin_theta);
                i = 0;
                while (i < a.len) : (i += 1) out[i] = a[i] * coef_a + b[i] * coef_b;
            }
        },
        .ties => {
            var i: usize = 0;
            while (i < a.len) : (i += 1) out[i] = (a[i] + b[i]) * 0.5;
        },
    }

    return out;
}

pub const MergeBytesResult = struct {
    report: MergeReport,
    bytes: []u8,
};

pub fn mergeSafetensors(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_a: []const u8,
    path_b: []const u8,
    output_path: []const u8,
    strategy: MergeStrategy,
    alpha: f64,
) !MergeReport {
    const data_a = try std.Io.Dir.cwd().readFileAlloc(io, path_a, allocator, .unlimited);
    defer allocator.free(data_a);
    const data_b = try std.Io.Dir.cwd().readFileAlloc(io, path_b, allocator, .unlimited);
    defer allocator.free(data_b);

    const result = try mergeSafetensorsBytes(allocator, data_a, data_b, strategy, alpha);
    defer allocator.free(result.bytes);

    const out_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    var out_buffer: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buffer);
    try out_writer.interface.writeAll(result.bytes);
    try out_writer.flush();

    return result.report;
}

pub fn mergeSafetensorsBytes(
    allocator: std.mem.Allocator,
    data_a: []const u8,
    data_b: []const u8,
    strategy: MergeStrategy,
    alpha: f64,
) !MergeBytesResult {
    var wf_a = try weight_diff.parseSafetensorsBytes(allocator, data_a);
    defer wf_a.deinit(allocator);
    var wf_b = try weight_diff.parseSafetensorsBytes(allocator, data_b);
    defer wf_b.deinit(allocator);

    var map_a = std.StringHashMap(usize).init(allocator);
    defer map_a.deinit();
    for (wf_a.tensors, 0..) |t, i| try map_a.put(t.name, i);

    var map_b = std.StringHashMap(usize).init(allocator);
    defer map_b.deinit();
    for (wf_b.tensors, 0..) |t, i| try map_b.put(t.name, i);

    var results = std.ArrayList(TensorMergeResult).empty;
    var n_merged: usize = 0;
    var n_passthrough: usize = 0;
    var n_conflict: usize = 0;

    var header_entries = std.ArrayList(u8).empty;
    var data_blob = std.ArrayList(u8).empty;
    var current_offset: usize = 0;
    try header_entries.appendSlice(allocator, "{");
    var first_entry = true;

    for (wf_b.tensors) |tb| {
        if (map_a.get(tb.name)) |ia| {
            const ta = wf_a.tensors[ia];
            const raw_a = data_a[ta.data_offset .. ta.data_offset + ta.data_len];
            const raw_b = data_b[tb.data_offset .. tb.data_offset + tb.data_len];

            if (!shapeEqual(ta.shape, tb.shape)) {
                n_conflict += 1;
                try results.append(allocator, .{
                    .name = try allocator.dupe(u8, tb.name),
                    .status = .shape_conflict,
                    .shape = try allocator.dupe(usize, tb.shape),
                    .dtype = tb.dtype,
                });
                try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tb.name, tb.dtype, tb.shape, raw_b, &first_entry);
                continue;
            }

            const target_dtype = if (ta.dtype == tb.dtype) ta.dtype else .f32;

            const vals_a = decodeToF32(allocator, ta.dtype, raw_a) catch {
                n_conflict += 1;
                try results.append(allocator, .{
                    .name = try allocator.dupe(u8, tb.name),
                    .status = .dtype_conflict,
                    .shape = try allocator.dupe(usize, tb.shape),
                    .dtype = tb.dtype,
                });
                try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tb.name, tb.dtype, tb.shape, raw_b, &first_entry);
                continue;
            };
            defer allocator.free(vals_a);

            const vals_b = decodeToF32(allocator, tb.dtype, raw_b) catch {
                n_conflict += 1;
                try results.append(allocator, .{
                    .name = try allocator.dupe(u8, tb.name),
                    .status = .dtype_conflict,
                    .shape = try allocator.dupe(usize, tb.shape),
                    .dtype = tb.dtype,
                });
                try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tb.name, tb.dtype, tb.shape, raw_b, &first_entry);
                continue;
            };
            defer allocator.free(vals_b);

            const merged = try mergeValues(allocator, vals_a, vals_b, strategy, alpha);
            defer allocator.free(merged);

            const encoded = try encodeFromF32(allocator, target_dtype, merged);
            defer allocator.free(encoded);

            n_merged += 1;
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, tb.name),
                .status = .merged,
                .shape = try allocator.dupe(usize, tb.shape),
                .dtype = target_dtype,
            });
            try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tb.name, target_dtype, tb.shape, encoded, &first_entry);
        } else {
            n_passthrough += 1;
            const raw_b = data_b[tb.data_offset .. tb.data_offset + tb.data_len];
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, tb.name),
                .status = .passthrough_b,
                .shape = try allocator.dupe(usize, tb.shape),
                .dtype = tb.dtype,
            });
            try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tb.name, tb.dtype, tb.shape, raw_b, &first_entry);
        }
    }

    for (wf_a.tensors) |ta| {
        if (map_b.get(ta.name) == null) {
            n_passthrough += 1;
            const raw_a = data_a[ta.data_offset .. ta.data_offset + ta.data_len];
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, ta.name),
                .status = .passthrough_a,
                .shape = try allocator.dupe(usize, ta.shape),
                .dtype = ta.dtype,
            });
            try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, ta.name, ta.dtype, ta.shape, raw_a, &first_entry);
        }
    }

    try header_entries.appendSlice(allocator, "}");

    var pad = (8 - header_entries.items.len % 8) % 8;
    while (pad > 0) : (pad -= 1) try header_entries.append(allocator, ' ');

    var final_bytes = std.ArrayList(u8).empty;
    var header_len_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &header_len_bytes, header_entries.items.len, .little);
    try final_bytes.appendSlice(allocator, &header_len_bytes);
    try final_bytes.appendSlice(allocator, header_entries.items);
    try final_bytes.appendSlice(allocator, data_blob.items);

    header_entries.deinit(allocator);
    data_blob.deinit(allocator);

    return MergeBytesResult{
        .report = MergeReport{
            .results = try results.toOwnedSlice(allocator),
            .n_merged = n_merged,
            .n_passthrough = n_passthrough,
            .n_conflict = n_conflict,
        },
        .bytes = try final_bytes.toOwnedSlice(allocator),
    };
}

pub fn mergeSafetensorsBytesTies(
    allocator: std.mem.Allocator,
    data_base: []const u8,
    data_a: []const u8,
    data_b: []const u8,
    density: f64,
    lambda: f64,
) !MergeBytesResult {
    var wf_base = try weight_diff.parseSafetensorsBytes(allocator, data_base);
    defer wf_base.deinit(allocator);
    var wf_a = try weight_diff.parseSafetensorsBytes(allocator, data_a);
    defer wf_a.deinit(allocator);
    var wf_b = try weight_diff.parseSafetensorsBytes(allocator, data_b);
    defer wf_b.deinit(allocator);

    var map_base = std.StringHashMap(usize).init(allocator);
    defer map_base.deinit();
    for (wf_base.tensors, 0..) |t, i| try map_base.put(t.name, i);

    var map_a = std.StringHashMap(usize).init(allocator);
    defer map_a.deinit();
    for (wf_a.tensors, 0..) |t, i| try map_a.put(t.name, i);

    var map_b = std.StringHashMap(usize).init(allocator);
    defer map_b.deinit();
    for (wf_b.tensors, 0..) |t, i| try map_b.put(t.name, i);

    var results = std.ArrayList(TensorMergeResult).empty;
    var n_merged: usize = 0;
    var n_passthrough: usize = 0;
    var n_conflict: usize = 0;

    var total_conflict_count: usize = 0;
    var total_conflict_denom: usize = 0;

    var header_entries = std.ArrayList(u8).empty;
    var data_blob = std.ArrayList(u8).empty;
    var current_offset: usize = 0;
    try header_entries.appendSlice(allocator, "{");
    var first_entry = true;

    for (wf_base.tensors) |tbase| {
        const ia = map_a.get(tbase.name);
        const ib = map_b.get(tbase.name);

        if (ia == null or ib == null) {
            const passthrough_raw = if (ia) |idx| blk: {
                const t = wf_a.tensors[idx];
                break :blk data_a[t.data_offset .. t.data_offset + t.data_len];
            } else if (ib) |idx| blk: {
                const t = wf_b.tensors[idx];
                break :blk data_b[t.data_offset .. t.data_offset + t.data_len];
            } else data_base[tbase.data_offset .. tbase.data_offset + tbase.data_len];

            n_passthrough += 1;
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, tbase.name),
                .status = .passthrough_a,
                .shape = try allocator.dupe(usize, tbase.shape),
                .dtype = tbase.dtype,
            });
            try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tbase.name, tbase.dtype, tbase.shape, passthrough_raw, &first_entry);
            continue;
        }

        const ta = wf_a.tensors[ia.?];
        const tb = wf_b.tensors[ib.?];

        if (!shapeEqual(tbase.shape, ta.shape) or !shapeEqual(tbase.shape, tb.shape)) {
            n_conflict += 1;
            const raw_a = data_a[ta.data_offset .. ta.data_offset + ta.data_len];
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, tbase.name),
                .status = .shape_conflict,
                .shape = try allocator.dupe(usize, ta.shape),
                .dtype = ta.dtype,
            });
            try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tbase.name, ta.dtype, ta.shape, raw_a, &first_entry);
            continue;
        }

        const raw_base = data_base[tbase.data_offset .. tbase.data_offset + tbase.data_len];
        const raw_a = data_a[ta.data_offset .. ta.data_offset + ta.data_len];
        const raw_b = data_b[tb.data_offset .. tb.data_offset + tb.data_len];

        const vals_base = decodeToF32(allocator, tbase.dtype, raw_base) catch {
            n_conflict += 1;
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, tbase.name),
                .status = .dtype_conflict,
                .shape = try allocator.dupe(usize, tbase.shape),
                .dtype = tbase.dtype,
            });
            try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tbase.name, ta.dtype, ta.shape, raw_a, &first_entry);
            continue;
        };
        defer allocator.free(vals_base);

        const vals_a = try decodeToF32(allocator, ta.dtype, raw_a);
        defer allocator.free(vals_a);
        const vals_b = try decodeToF32(allocator, tb.dtype, raw_b);
        defer allocator.free(vals_b);

        const task_a = try weight_ties.computeTaskVector(allocator, vals_base, vals_a);
        defer allocator.free(task_a);
        const task_b = try weight_ties.computeTaskVector(allocator, vals_base, vals_b);
        defer allocator.free(task_b);

        const magnitude_threshold: f32 = 1e-6;
        const conflict_stats = weight_ties.computeConflictStats(task_a, task_b, magnitude_threshold);
        total_conflict_count += conflict_stats.n_conflict;
        total_conflict_denom += conflict_stats.n_total;

        const task_vectors = [_][]const f32{ task_a, task_b };
        const merged_vals = try weight_ties.tiesMergeTensor(allocator, vals_base, &task_vectors, density, lambda);
        defer allocator.free(merged_vals);

        const target_dtype = if (ta.dtype == tb.dtype) ta.dtype else .f32;
        const encoded = try encodeFromF32(allocator, target_dtype, merged_vals);
        defer allocator.free(encoded);

        n_merged += 1;
        try results.append(allocator, .{
            .name = try allocator.dupe(u8, tbase.name),
            .status = .merged,
            .shape = try allocator.dupe(usize, tbase.shape),
            .dtype = target_dtype,
            .conflict_pct = conflict_stats.conflict_pct,
        });
        try appendTensorEntry(allocator, &header_entries, &data_blob, &current_offset, tbase.name, target_dtype, tbase.shape, encoded, &first_entry);
    }

    try header_entries.appendSlice(allocator, "}");

    var pad = (8 - header_entries.items.len % 8) % 8;
    while (pad > 0) : (pad -= 1) try header_entries.append(allocator, ' ');

    var final_bytes = std.ArrayList(u8).empty;
    var header_len_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &header_len_bytes, header_entries.items.len, .little);
    try final_bytes.appendSlice(allocator, &header_len_bytes);
    try final_bytes.appendSlice(allocator, header_entries.items);
    try final_bytes.appendSlice(allocator, data_blob.items);

    header_entries.deinit(allocator);
    data_blob.deinit(allocator);

    const overall_pct: ?f64 = if (total_conflict_denom > 0)
        @as(f64, @floatFromInt(total_conflict_count)) / @as(f64, @floatFromInt(total_conflict_denom)) * 100.0
    else
        null;

    return MergeBytesResult{
        .report = MergeReport{
            .results = try results.toOwnedSlice(allocator),
            .n_merged = n_merged,
            .n_passthrough = n_passthrough,
            .n_conflict = n_conflict,
            .overall_conflict_pct = overall_pct,
        },
        .bytes = try final_bytes.toOwnedSlice(allocator),
    };
}

fn appendTensorEntry(
    allocator: std.mem.Allocator,
    header: *std.ArrayList(u8),
    blob: *std.ArrayList(u8),
    offset: *usize,
    name: []const u8,
    dtype: weight_diff.DType,
    shape: []const usize,
    raw: []const u8,
    first: *bool,
) !void {
    if (!first.*) try header.appendSlice(allocator, ",");
    first.* = false;

    try header.appendSlice(allocator, "\"");
    try header.appendSlice(allocator, name);
    try header.appendSlice(allocator, "\":{\"dtype\":\"");

    const dtype_str = switch (dtype) {
        .f32 => "F32",
        .f16 => "F16",
        .bf16 => "BF16",
        .f64 => "F64",
        .i32 => "I32",
        .i64 => "I64",
        .i8 => "I8",
        .u8 => "U8",
        .bool_t => "BOOL",
        .unknown => "F32",
    };
    try header.appendSlice(allocator, dtype_str);
    try header.appendSlice(allocator, "\",\"shape\":[");

    for (shape, 0..) |d, i| {
        if (i > 0) try header.appendSlice(allocator, ",");
        const s = try std.fmt.allocPrint(allocator, "{d}", .{d});
        defer allocator.free(s);
        try header.appendSlice(allocator, s);
    }

    const start = offset.*;
    const end = start + raw.len;
    const off_str = try std.fmt.allocPrint(allocator, "],\"data_offsets\":[{d},{d}]}}", .{ start, end });
    defer allocator.free(off_str);
    try header.appendSlice(allocator, off_str);

    try blob.appendSlice(allocator, raw);
    offset.* = end;
}

pub fn printMergeReport(report: *const MergeReport, output_path: []const u8) void {
    std.debug.print("\n🧬 Model Merge Report\n\n", .{});
    std.debug.print("   Output: {s}\n\n", .{output_path});
    std.debug.print("   ✅ merged:      {d} tensor(s)\n", .{report.n_merged});
    std.debug.print("   ➡️  passthrough: {d} tensor(s)\n", .{report.n_passthrough});
    std.debug.print("   ⚠️  conflicts:   {d} tensor(s)\n", .{report.n_conflict});
    if (report.overall_conflict_pct) |pct| {
        std.debug.print("   🔀 sign conflicts: {d:.1}% of parameters (resolved via TIES)\n", .{pct});
    }
    std.debug.print("\n", .{});

    var shown_per_tensor_conflict = false;
    for (report.results) |r| {
        if (r.conflict_pct) |cp| {
            if (cp > 5.0) {
                if (!shown_per_tensor_conflict) {
                    std.debug.print("   High-conflict layers (>5% sign disagreement):\n", .{});
                    shown_per_tensor_conflict = true;
                }
                std.debug.print("      ⚠️  {s}  ({d:.1}% conflict)\n", .{ r.name, cp });
            }
        }
    }
    if (shown_per_tensor_conflict) std.debug.print("\n", .{});

    if (report.n_conflict > 0) {
        std.debug.print("   Conflicts (kept from second model, not merged):\n", .{});
        for (report.results) |r| {
            if (r.status == .shape_conflict) {
                std.debug.print("      ⚠️  {s}  (shape mismatch)\n", .{r.name});
            } else if (r.status == .dtype_conflict) {
                std.debug.print("      ⚠️  {s}  (unsupported dtype)\n", .{r.name});
            }
        }
        std.debug.print("\n", .{});
    }
}
