const std = @import("std");

pub const DType = enum {
    f32,
    f16,
    bf16,
    f64,
    i32,
    i64,
    i8,
    u8,
    bool_t,
    unknown,

    pub fn fromStr(s: []const u8) DType {
        if (std.mem.eql(u8, s, "F32") or std.mem.eql(u8, s, "float32")) return .f32;
        if (std.mem.eql(u8, s, "F16") or std.mem.eql(u8, s, "float16")) return .f16;
        if (std.mem.eql(u8, s, "BF16") or std.mem.eql(u8, s, "bfloat16")) return .bf16;
        if (std.mem.eql(u8, s, "F64") or std.mem.eql(u8, s, "float64")) return .f64;
        if (std.mem.eql(u8, s, "I32") or std.mem.eql(u8, s, "int32")) return .i32;
        if (std.mem.eql(u8, s, "I64") or std.mem.eql(u8, s, "int64")) return .i64;
        if (std.mem.eql(u8, s, "I8") or std.mem.eql(u8, s, "int8")) return .i8;
        if (std.mem.eql(u8, s, "U8") or std.mem.eql(u8, s, "uint8")) return .u8;
        if (std.mem.eql(u8, s, "BOOL") or std.mem.eql(u8, s, "bool")) return .bool_t;
        return .unknown;
    }

    pub fn bytesPerElement(self: DType) usize {
        return switch (self) {
            .f64, .i64 => 8,
            .f32, .i32 => 4,
            .f16, .bf16 => 2,
            .i8, .u8, .bool_t => 1,
            .unknown => 4,
        };
    }

    pub fn label(self: DType) []const u8 {
        return switch (self) {
            .f32 => "float32",
            .f16 => "float16",
            .bf16 => "bfloat16",
            .f64 => "float64",
            .i32 => "int32",
            .i64 => "int64",
            .i8 => "int8",
            .u8 => "uint8",
            .bool_t => "bool",
            .unknown => "unknown",
        };
    }
};

pub const TensorInfo = struct {
    name: []u8,
    shape: []usize,
    dtype: DType,
    num_params: usize,
    l2_norm: f64,
    mean: f64,
    std_dev: f64,
    sparsity: f64,
    data_offset: usize,
    data_len: usize,
    quant_label: []const u8 = "",

    pub fn deinit(self: TensorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.shape);
    }

    pub fn shapeStr(self: TensorInfo, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        try buf.append(allocator, '[');
        for (self.shape, 0..) |dim, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            const s = try std.fmt.allocPrint(allocator, "{d}", .{dim});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        try buf.append(allocator, ']');
        return buf.toOwnedSlice(allocator);
    }
};

pub const WeightFile = struct {
    pub const Format = enum { safetensors, npy, npz, pytorch, gguf, unknown };
    format: Format,
    tensors: []TensorInfo,
    total_params: usize,
    total_bytes: usize,

    pub fn deinit(self: WeightFile, allocator: std.mem.Allocator) void {
        for (self.tensors) |t| t.deinit(allocator);
        allocator.free(self.tensors);
    }
};

pub const TensorDiff = struct {
    pub const Change = enum { added, removed, modified, unchanged };
    name: []u8,
    change: Change,
    dtype_a: DType,
    dtype_b: DType,
    shape_a: []usize,
    shape_b: []usize,
    params_a: usize,
    params_b: usize,
    norm_a: f64,
    norm_b: f64,
    norm_delta_pct: f64,
    mean_a: f64,
    mean_b: f64,
    std_a: f64,
    std_b: f64,
    sparsity_a: f64,
    sparsity_b: f64,
    cosine_sim: f64,
    quant_label_a: []const u8 = "",
    quant_label_b: []const u8 = "",
    approx_similarity: ?f64 = null,

    pub fn deinit(self: *TensorDiff, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.shape_a);
        allocator.free(self.shape_b);
    }
};

pub const WeightDiff = struct {
    file_a: []const u8,
    file_b: []const u8,
    format_a: WeightFile.Format,
    format_b: WeightFile.Format,
    tensors: []TensorDiff,
    total_params_a: usize,
    total_params_b: usize,
    total_bytes_a: usize,
    total_bytes_b: usize,
    arch_changed: bool,

    pub fn deinit(self: *WeightDiff, allocator: std.mem.Allocator) void {
        for (self.tensors) |*t| t.deinit(allocator);
        allocator.free(self.tensors);
    }
};

fn detectFormat(path: []const u8) WeightFile.Format {
    if (std.mem.endsWith(u8, path, ".safetensors")) return .safetensors;
    if (std.mem.endsWith(u8, path, ".npz")) return .npz;
    if (std.mem.endsWith(u8, path, ".npy")) return .npy;
    if (std.mem.endsWith(u8, path, ".gguf")) return .gguf;
    if (std.mem.endsWith(u8, path, ".pt") or
        std.mem.endsWith(u8, path, ".pth") or
        std.mem.endsWith(u8, path, ".bin")) return .pytorch;
    return .unknown;
}

fn shapeEqual(a: []usize, b: []usize) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn computeParams(shape: []usize) usize {
    if (shape.len == 0) return 1;
    var n: usize = 1;
    for (shape) |d| n *= d;
    return n;
}

const Stats = struct { l2: f64, mean: f64, std_dev: f64, sparsity: f64 };

fn computeF32Stats(data: []const u8) Stats {
    if (data.len < 4) return .{ .l2 = 0, .mean = 0, .std_dev = 0, .sparsity = 0 };
    const n = data.len / 4;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var near_zero: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bits = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        const val: f32 = @bitCast(bits);
        const vf: f64 = @floatCast(val);
        if (!std.math.isNan(vf) and !std.math.isInf(vf)) {
            sum += vf;
            sum_sq += vf * vf;
            if (@abs(vf) < 1e-6) near_zero += 1;
        }
    }
    const fn_: f64 = @floatFromInt(n);
    const mean = sum / fn_;
    const variance = (sum_sq / fn_) - (mean * mean);
    return .{
        .l2 = @sqrt(sum_sq),
        .mean = mean,
        .std_dev = if (variance > 0) @sqrt(variance) else 0,
        .sparsity = @as(f64, @floatFromInt(near_zero)) / fn_ * 100.0,
    };
}

fn computeF16Stats(data: []const u8) Stats {
    if (data.len < 2) return .{ .l2 = 0, .mean = 0, .std_dev = 0, .sparsity = 0 };
    const n = data.len / 2;
    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    var near_zero: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bits = std.mem.readInt(u16, data[i * 2 ..][0..2], .little);
        const sign: f64 = if ((bits & 0x8000) != 0) -1.0 else 1.0;
        const exp: i32 = @intCast((bits >> 10) & 0x1F);
        const mant: u16 = bits & 0x3FF;
        const vf: f64 = if (exp == 0)
            sign * @as(f64, @floatFromInt(mant)) / 16777216.0
        else if (exp == 31)
            0.0
        else blk: {
            const m: f64 = 1.0 + @as(f64, @floatFromInt(mant)) / 1024.0;
            const e: f64 = @floatFromInt(exp - 15);
            break :blk sign * m * std.math.pow(f64, 2.0, e);
        };
        sum += vf;
        sum_sq += vf * vf;
        if (@abs(vf) < 1e-4) near_zero += 1;
    }
    const fn_: f64 = @floatFromInt(n);
    const mean = sum / fn_;
    const variance = (sum_sq / fn_) - (mean * mean);
    return .{
        .l2 = @sqrt(sum_sq),
        .mean = mean,
        .std_dev = if (variance > 0) @sqrt(variance) else 0,
        .sparsity = @as(f64, @floatFromInt(near_zero)) / fn_ * 100.0,
    };
}

fn computeStats(data: []const u8, dtype: DType) Stats {
    return switch (dtype) {
        .f32 => computeF32Stats(data),
        .f16, .bf16 => computeF16Stats(data),
        else => .{ .l2 = 0, .mean = 0, .std_dev = 0, .sparsity = 0 },
    };
}

fn computeCosine(data_a: []const u8, data_b: []const u8) f64 {
    const n = @min(data_a.len, data_b.len) / 4;
    if (n == 0) return 0;
    const limit = @min(n, 16384);
    var dot: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const va: f32 = @bitCast(std.mem.readInt(u32, data_a[i * 4 ..][0..4], .little));
        const vb: f32 = @bitCast(std.mem.readInt(u32, data_b[i * 4 ..][0..4], .little));
        const fa: f64 = @floatCast(va);
        const fb: f64 = @floatCast(vb);
        dot += fa * fb;
        norm_a += fa * fa;
        norm_b += fb * fb;
    }
    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom < 1e-12) return 0;
    return dot / denom;
}

fn jsonStr(json: []const u8, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key});
    defer allocator.free(needle);
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = pos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') i += 1;
    return try allocator.dupe(u8, json[start..i]);
}

fn jsonShape(json: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]usize {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key});
    defer allocator.free(needle);
    const kpos = std.mem.indexOf(u8, json, needle) orelse return allocator.alloc(usize, 0);
    var i = kpos + needle.len;
    while (i < json.len and json[i] != '[') i += 1;
    if (i >= json.len) return allocator.alloc(usize, 0);
    i += 1;
    var dims = std.ArrayList(usize).empty;
    while (i < json.len and json[i] != ']') {
        while (i < json.len and (json[i] == ' ' or json[i] == ',')) i += 1;
        if (i < json.len and json[i] == ']') break;
        const start = i;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
        if (i > start) try dims.append(allocator, std.fmt.parseInt(usize, json[start..i], 10) catch 0);
    }
    return dims.toOwnedSlice(allocator);
}

fn jsonOffsets(json: []const u8, key: []const u8) struct { start: usize, end: usize } {
    const kpos = std.mem.indexOf(u8, json, key) orelse return .{ .start = 0, .end = 0 };
    var i = kpos + key.len;
    while (i < json.len and json[i] != '[') i += 1;
    if (i >= json.len) return .{ .start = 0, .end = 0 };
    i += 1;
    while (i < json.len and json[i] == ' ') i += 1;
    const s1 = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    const off_a = std.fmt.parseInt(usize, json[s1..i], 10) catch 0;
    while (i < json.len and (json[i] == ' ' or json[i] == ',')) i += 1;
    const s2 = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    const off_b = std.fmt.parseInt(usize, json[s2..i], 10) catch 0;
    return .{ .start = off_a, .end = off_b };
}

fn jsonF64(json: []const u8, key: []const u8) f64 {
    const needle = key;
    const kpos = std.mem.indexOf(u8, json, needle) orelse return 0;
    var i = kpos + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '"')) i += 1;
    const start = i;
    while (i < json.len and (json[i] == '.' or json[i] == '-' or json[i] == 'e' or
        json[i] == 'E' or json[i] == '+' or (json[i] >= '0' and json[i] <= '9'))) i += 1;
    return std.fmt.parseFloat(f64, json[start..i]) catch 0;
}

pub fn parseSafetensors(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !WeightFile {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(20 * 1024 * 1024 * 1024));
    defer allocator.free(data);
    return parseSafetensorsBytes(allocator, data);
}

pub fn parseSafetensorsBytes(allocator: std.mem.Allocator, data: []const u8) !WeightFile {
    if (data.len < 8) return error.InvalidFormat;
    const header_len = std.mem.readInt(u64, data[0..8], .little);
    if (header_len == 0 or 8 + header_len > data.len) return error.InvalidFormat;

    const header = data[8 .. 8 + header_len];
    const data_base: usize = 8 + header_len;

    var tensors = std.ArrayList(TensorInfo).empty;
    var total_params: usize = 0;
    var total_bytes: usize = 0;

    var i: usize = 1;
    while (i < header.len) {
        while (i < header.len and header[i] != '"') i += 1;
        if (i >= header.len) break;
        i += 1;
        const name_start = i;
        while (i < header.len and header[i] != '"') i += 1;
        if (i >= header.len) break;
        const tname = header[name_start..i];
        i += 1;

        if (std.mem.eql(u8, tname, "__metadata__")) {
            var depth: usize = 0;
            while (i < header.len) : (i += 1) {
                if (header[i] == '{') depth += 1;
                if (header[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        i += 1;
                        break;
                    }
                }
            }
            continue;
        }

        while (i < header.len and header[i] != '{') i += 1;
        if (i >= header.len) break;
        const obj_start = i;
        var depth: usize = 0;
        while (i < header.len) : (i += 1) {
            if (header[i] == '{') depth += 1;
            if (header[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    i += 1;
                    break;
                }
            }
        }
        const obj = header[obj_start..i];

        const dtype_s = (try jsonStr(obj, "dtype", allocator)) orelse try allocator.dupe(u8, "F32");
        defer allocator.free(dtype_s);
        const dtype = DType.fromStr(dtype_s);
        const shape = try jsonShape(obj, "shape", allocator);
        const offsets = jsonOffsets(obj, "data_offsets");
        const abs_start = data_base + offsets.start;
        const abs_end = data_base + offsets.end;
        const n_params = computeParams(shape);
        total_params += n_params;

        var stats = Stats{ .l2 = 0, .mean = 0, .std_dev = 0, .sparsity = 0 };
        if (abs_end <= data.len and abs_start < abs_end) {
            total_bytes += abs_end - abs_start;
            stats = computeStats(data[abs_start..abs_end], dtype);
        }

        try tensors.append(allocator, .{
            .name = try allocator.dupe(u8, tname),
            .shape = shape,
            .dtype = dtype,
            .num_params = n_params,
            .l2_norm = stats.l2,
            .mean = stats.mean,
            .std_dev = stats.std_dev,
            .sparsity = stats.sparsity,
            .data_offset = abs_start,
            .data_len = if (abs_end > abs_start) abs_end - abs_start else 0,
        });
    }

    return WeightFile{
        .format = .safetensors,
        .tensors = try tensors.toOwnedSlice(allocator),
        .total_params = total_params,
        .total_bytes = total_bytes,
    };
}

pub fn parseNpy(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !WeightFile {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024 * 1024));
    defer allocator.free(data);

    if (data.len < 10) return error.InvalidFormat;
    if (data[0] != 0x93) return error.InvalidFormat;
    if (!std.mem.eql(u8, data[1..6], "NUMPY")) return error.InvalidFormat;

    const hdr_len: usize = std.mem.readInt(u16, data[8..10], .little);
    if (10 + hdr_len > data.len) return error.InvalidFormat;
    const hdr = data[10 .. 10 + hdr_len];

    var dtype: DType = .f32;
    if (std.mem.indexOf(u8, hdr, "'f4'") != null) dtype = .f32;
    if (std.mem.indexOf(u8, hdr, "'f2'") != null) dtype = .f16;
    if (std.mem.indexOf(u8, hdr, "'f8'") != null) dtype = .f64;
    if (std.mem.indexOf(u8, hdr, "'i4'") != null) dtype = .i32;
    if (std.mem.indexOf(u8, hdr, "'i8'") != null) dtype = .i64;
    if (std.mem.indexOf(u8, hdr, "'i1'") != null) dtype = .i8;
    if (std.mem.indexOf(u8, hdr, "'u1'") != null) dtype = .u8;

    var shape = std.ArrayList(usize).empty;
    if (std.mem.indexOf(u8, hdr, "'shape': (")) |sp| {
        var si = sp + 10;
        while (si < hdr.len and hdr[si] != ')') {
            while (si < hdr.len and (hdr[si] == ' ' or hdr[si] == ',')) si += 1;
            if (si < hdr.len and hdr[si] == ')') break;
            const ds = si;
            while (si < hdr.len and hdr[si] >= '0' and hdr[si] <= '9') si += 1;
            if (si > ds) try shape.append(allocator, std.fmt.parseInt(usize, hdr[ds..si], 10) catch 0);
        }
    }

    const tdata = data[10 + hdr_len ..];
    const n_params = computeParams(shape.items);
    const stats = computeStats(tdata, dtype);

    const base = if (std.mem.lastIndexOf(u8, path, "/")) |p| p + 1 else 0;
    const fname = path[base..];
    const name = if (std.mem.lastIndexOf(u8, fname, ".")) |p| fname[0..p] else fname;

    const tensors = try allocator.alloc(TensorInfo, 1);
    tensors[0] = .{
        .name = try allocator.dupe(u8, name),
        .shape = try shape.toOwnedSlice(allocator),
        .dtype = dtype,
        .num_params = n_params,
        .l2_norm = stats.l2,
        .mean = stats.mean,
        .std_dev = stats.std_dev,
        .sparsity = stats.sparsity,
        .data_offset = 10 + hdr_len,
        .data_len = tdata.len,
    };

    return WeightFile{
        .format = .npy,
        .tensors = tensors,
        .total_params = n_params,
        .total_bytes = tdata.len,
    };
}

fn parseViaHelper(io: std.Io, allocator: std.mem.Allocator, script: []const u8, tmp_path: []const u8, path: []const u8, fmt: WeightFile.Format) !WeightFile {
    const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var f_buffer: [4096]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    try f_writer.interface.writeAll(script);
    try f_writer.flush();
    f.close(io);

    var out_buf: [4 * 1024 * 1024]u8 = undefined;
    var n: usize = 0;

    if (std.process.spawn(io, .{
        .argv = &.{ "python3", tmp_path, path },
        .stdout = .pipe,
        .stderr = .ignore,
    })) |child_result| {
        var child = child_result;
        var child_scratch: [4096]u8 = undefined;
        var child_reader = child.stdout.?.reader(io, &child_scratch);
        n = child_reader.interface.readSliceShort(&out_buf) catch 0;
        _ = child.wait(io) catch {};
    } else |_| {}

    if (n == 0) return error.HelperFailed;
    const json_out = out_buf[0..n];

    var tensors = std.ArrayList(TensorInfo).empty;
    var total_params: usize = 0;
    var total_bytes: usize = 0;

    var depth: usize = 0;
    var obj_start: usize = 0;
    var in_str = false;
    var j: usize = 0;
    while (j < json_out.len) : (j += 1) {
        const c = json_out[j];
        if (c == '"' and (j == 0 or json_out[j - 1] != '\\')) in_str = !in_str;
        if (in_str) continue;
        if (c == '{') {
            if (depth == 0) obj_start = j;
            depth += 1;
        }
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                const obj = json_out[obj_start .. j + 1];
                const tname = (try jsonStr(obj, "name", allocator)) orelse continue;
                const dtype_s = (try jsonStr(obj, "dtype", allocator)) orelse try allocator.dupe(u8, "float32");
                defer allocator.free(dtype_s);
                const shape = try jsonShape(obj, "shape", allocator);
                const n_params = computeParams(shape);
                const l2 = jsonF64(obj, "\"l2\":");
                const mn = jsonF64(obj, "\"mean\":");
                const sd = jsonF64(obj, "\"std\":");
                const sp = jsonF64(obj, "\"sparsity\":");
                const bpe = DType.fromStr(dtype_s).bytesPerElement();
                total_params += n_params;
                total_bytes += n_params * bpe;
                try tensors.append(allocator, .{
                    .name = tname,
                    .shape = shape,
                    .dtype = DType.fromStr(dtype_s),
                    .num_params = n_params,
                    .l2_norm = l2,
                    .mean = mn,
                    .std_dev = sd,
                    .sparsity = sp,
                    .data_offset = 0,
                    .data_len = n_params * bpe,
                });
            }
        }
    }

    return WeightFile{
        .format = fmt,
        .tensors = try tensors.toOwnedSlice(allocator),
        .total_params = total_params,
        .total_bytes = total_bytes,
    };
}

pub fn parsePyTorch(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !WeightFile {
    const script =
        \\import sys, json, torch
        \\path = sys.argv[1]
        \\try:
        \\    state = torch.load(path, map_location='cpu', weights_only=True)
        \\except Exception:
        \\    state = torch.load(path, map_location='cpu')
        \\if hasattr(state, 'state_dict'):
        \\    state = state.state_dict()
        \\results = []
        \\for k, v in state.items():
        \\    if not hasattr(v, 'shape'): continue
        \\    flat = v.float().flatten()
        \\    n = flat.numel()
        \\    results.append({'name': k, 'shape': list(v.shape),
        \\        'dtype': str(v.dtype).replace('torch.',''),
        \\        'l2': float(flat.norm(2)) if n>0 else 0,
        \\        'mean': float(flat.mean()) if n>0 else 0,
        \\        'std': float(flat.std()) if n>1 else 0,
        \\        'sparsity': float((flat.abs()<1e-6).float().mean())*100, 'n': n})
        \\print(json.dumps(results))
    ;
    return parseViaHelper(io, allocator, script, "/tmp/zev_pt_inspect.py", path, .pytorch);
}

pub fn parseNpz(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !WeightFile {
    const script =
        \\import sys, json, numpy as np
        \\path = sys.argv[1]
        \\data = np.load(path, allow_pickle=False)
        \\results = []
        \\for k in data.files:
        \\    v = data[k]
        \\    flat = v.astype(np.float64).flatten()
        \\    n = flat.size
        \\    results.append({'name': k, 'shape': list(v.shape),
        \\        'dtype': str(v.dtype),
        \\        'l2': float(np.linalg.norm(flat)) if n>0 else 0,
        \\        'mean': float(flat.mean()) if n>0 else 0,
        \\        'std': float(flat.std()) if n>1 else 0,
        \\        'sparsity': float(np.mean(np.abs(flat)<1e-6))*100, 'n': n})
        \\print(json.dumps(results))
    ;
    return parseViaHelper(io, allocator, script, "/tmp/zev_npz_inspect.py", path, .npz);
}

pub fn parseWeightFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !WeightFile {
    const fmt = detectFormat(path);
    return switch (fmt) {
        .safetensors => parseSafetensors(io, allocator, path),
        .npy => parseNpy(io, allocator, path),
        .npz => blk: {
            const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch
                return error.CannotReadFile;
            defer allocator.free(raw);
            break :blk parseNpzPureZig(allocator, raw) catch
                parseNpz(io, allocator, path);
        },
        .gguf => parseGguf(io, allocator, path),
        .pytorch => parsePyTorch(io, allocator, path),
        .unknown => parseSafetensors(io, allocator, path) catch
            parseNpy(io, allocator, path) catch
            parseGguf(io, allocator, path) catch
            parsePyTorch(io, allocator, path),
    };
}

pub fn computeWeightDiff(
    allocator: std.mem.Allocator,
    wf_a: *const WeightFile,
    wf_b: *const WeightFile,
    raw_a: ?[]const u8,
    raw_b: ?[]const u8,
    file_a: []const u8,
    file_b: []const u8,
) !WeightDiff {
    var diffs = std.ArrayList(TensorDiff).empty;
    var arch_changed = false;

    var map_a = std.StringHashMap(usize).init(allocator);
    defer map_a.deinit();
    for (wf_a.tensors, 0..) |t, i| try map_a.put(t.name, i);

    var map_b = std.StringHashMap(usize).init(allocator);
    defer map_b.deinit();
    for (wf_b.tensors, 0..) |t, i| try map_b.put(t.name, i);

    for (wf_b.tensors) |tb| {
        if (map_a.get(tb.name)) |ia| {
            const ta = wf_a.tensors[ia];
            const same_shape = shapeEqual(ta.shape, tb.shape);
            if (!same_shape or ta.dtype != tb.dtype) arch_changed = true;

            const norm_delta_pct: f64 = if (ta.l2_norm > 1e-12)
                ((tb.l2_norm - ta.l2_norm) / ta.l2_norm) * 100.0
            else
                0.0;

            var cosine: f64 = 1.0;
            if (!same_shape or ta.num_params != tb.num_params) {
                cosine = 0.0;
            } else if (raw_a != null and raw_b != null and
                ta.dtype == .f32 and tb.dtype == .f32 and
                ta.data_offset + ta.data_len <= raw_a.?.len and
                tb.data_offset + tb.data_len <= raw_b.?.len)
            {
                cosine = computeCosine(
                    raw_a.?[ta.data_offset .. ta.data_offset + ta.data_len],
                    raw_b.?[tb.data_offset .. tb.data_offset + tb.data_len],
                );
            }

            const changed = !same_shape or ta.dtype != tb.dtype or @abs(norm_delta_pct) > 0.01;

            try diffs.append(allocator, .{
                .name = try allocator.dupe(u8, tb.name),
                .change = if (changed) .modified else .unchanged,
                .dtype_a = ta.dtype,
                .dtype_b = tb.dtype,
                .shape_a = try allocator.dupe(usize, ta.shape),
                .shape_b = try allocator.dupe(usize, tb.shape),
                .params_a = ta.num_params,
                .params_b = tb.num_params,
                .norm_a = ta.l2_norm,
                .norm_b = tb.l2_norm,
                .norm_delta_pct = norm_delta_pct,
                .mean_a = ta.mean,
                .mean_b = tb.mean,
                .std_a = ta.std_dev,
                .std_b = tb.std_dev,
                .sparsity_a = ta.sparsity,
                .sparsity_b = tb.sparsity,
                .cosine_sim = cosine,
                .quant_label_a = ta.quant_label,
                .quant_label_b = tb.quant_label,
            });
        } else {
            arch_changed = true;
            try diffs.append(allocator, .{
                .name = try allocator.dupe(u8, tb.name),
                .change = .added,
                .dtype_a = .unknown,
                .dtype_b = tb.dtype,
                .shape_a = try allocator.alloc(usize, 0),
                .shape_b = try allocator.dupe(usize, tb.shape),
                .params_a = 0,
                .params_b = tb.num_params,
                .norm_a = 0,
                .norm_b = tb.l2_norm,
                .norm_delta_pct = 0,
                .mean_a = 0,
                .mean_b = tb.mean,
                .std_a = 0,
                .std_b = tb.std_dev,
                .sparsity_a = 0,
                .sparsity_b = tb.sparsity,
                .cosine_sim = 0,
            });
        }
    }

    for (wf_a.tensors) |ta| {
        if (map_b.get(ta.name) == null) {
            arch_changed = true;
            try diffs.append(allocator, .{
                .name = try allocator.dupe(u8, ta.name),
                .change = .removed,
                .dtype_a = ta.dtype,
                .dtype_b = .unknown,
                .shape_a = try allocator.dupe(usize, ta.shape),
                .shape_b = try allocator.alloc(usize, 0),
                .params_a = ta.num_params,
                .params_b = 0,
                .norm_a = ta.l2_norm,
                .norm_b = 0,
                .norm_delta_pct = 0,
                .mean_a = ta.mean,
                .mean_b = 0,
                .std_a = ta.std_dev,
                .std_b = 0,
                .sparsity_a = ta.sparsity,
                .sparsity_b = 0,
                .cosine_sim = 0,
            });
        }
    }

    return WeightDiff{
        .file_a = file_a,
        .file_b = file_b,
        .format_a = wf_a.format,
        .format_b = wf_b.format,
        .tensors = try diffs.toOwnedSlice(allocator),
        .total_params_a = wf_a.total_params,
        .total_params_b = wf_b.total_params,
        .total_bytes_a = wf_a.total_bytes,
        .total_bytes_b = wf_b.total_bytes,
        .arch_changed = arch_changed,
    };
}

fn fmtParams(n: usize, allocator: std.mem.Allocator) ![]u8 {
    if (n >= 1_000_000_000) return std.fmt.allocPrint(allocator, "{d:.2}B", .{@as(f64, @floatFromInt(n)) / 1e9});
    if (n >= 1_000_000) return std.fmt.allocPrint(allocator, "{d:.2}M", .{@as(f64, @floatFromInt(n)) / 1e6});
    if (n >= 1_000) return std.fmt.allocPrint(allocator, "{d:.1}K", .{@as(f64, @floatFromInt(n)) / 1e3});
    return std.fmt.allocPrint(allocator, "{d}", .{n});
}

fn fmtBytes(b: usize, allocator: std.mem.Allocator) ![]u8 {
    if (b >= 1024 * 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.2} GB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0 * 1024.0)});
    if (b >= 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} MB", .{@as(f64, @floatFromInt(b)) / (1024.0 * 1024.0)});
    if (b >= 1024) return std.fmt.allocPrint(allocator, "{d:.1} KB", .{@as(f64, @floatFromInt(b)) / 1024.0});
    return std.fmt.allocPrint(allocator, "{d} B", .{b});
}

fn makeShapeStr(allocator: std.mem.Allocator, shape: []usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '[');
    for (shape, 0..) |d, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const s = try std.fmt.allocPrint(allocator, "{d}", .{d});
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

pub fn printWeightDiff(allocator: std.mem.Allocator, diff: *const WeightDiff, show_unchanged: bool) !void {
    const fname_a = if (std.mem.lastIndexOf(u8, diff.file_a, "/")) |p| diff.file_a[p + 1 ..] else diff.file_a;
    const fname_b = if (std.mem.lastIndexOf(u8, diff.file_b, "/")) |p| diff.file_b[p + 1 ..] else diff.file_b;

    std.debug.print("\n⚖️  Weight Diff: {s} → {s}\n\n", .{ fname_a, fname_b });

    const pa = try fmtParams(diff.total_params_a, allocator);
    defer allocator.free(pa);
    const pb = try fmtParams(diff.total_params_b, allocator);
    defer allocator.free(pb);
    const ba = try fmtBytes(diff.total_bytes_a, allocator);
    defer allocator.free(ba);
    const bb = try fmtBytes(diff.total_bytes_b, allocator);
    defer allocator.free(bb);

    const param_delta: i64 = @as(i64, @intCast(diff.total_params_b)) - @as(i64, @intCast(diff.total_params_a));
    const param_pct: f64 = if (diff.total_params_a > 0)
        @as(f64, @floatFromInt(param_delta)) / @as(f64, @floatFromInt(diff.total_params_a)) * 100.0
    else
        0.0;
    const psign: []const u8 = if (param_delta >= 0) "+" else "";

    std.debug.print("   Parameters:   {s} → {s}  ({s}{d}  {s}{d:.1}%)\n", .{ pa, pb, psign, param_delta, psign, param_pct });
    std.debug.print("   Memory:       {s} → {s}\n", .{ ba, bb });
    std.debug.print("   Architecture: {s}\n\n", .{if (diff.arch_changed) "⚠️  CHANGED (not backward compatible)" else "✅ unchanged"});

    var n_added: usize = 0;
    var n_removed: usize = 0;
    var n_modified: usize = 0;
    var n_unchanged: usize = 0;
    for (diff.tensors) |t| switch (t.change) {
        .added => n_added += 1,
        .removed => n_removed += 1,
        .modified => n_modified += 1,
        .unchanged => n_unchanged += 1,
    };

    std.debug.print("   Layers:  🆕 {d} added   🗑️  {d} removed   ✏️  {d} modified   ➡️  {d} unchanged\n\n", .{ n_added, n_removed, n_modified, n_unchanged });

    std.debug.print("   {s:<42} {s:<12} {s:<22} {s:<12} {s:<12} {s}\n", .{ "Layer", "Change", "Shape", "Norm Δ%", "Sparsity", "Cosine" });
    std.debug.print("   {s}\n", .{"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"});

    for (diff.tensors) |t| {
        if (!show_unchanged and t.change == .unchanged) continue;

        const icon: []const u8 = switch (t.change) {
            .added => "🆕",
            .removed => "🗑️ ",
            .modified => "✏️ ",
            .unchanged => "➡️ ",
        };
        const clabel: []const u8 = switch (t.change) {
            .added => "added",
            .removed => "removed",
            .modified => "modified",
            .unchanged => "unchanged",
        };

        const maxname = @min(40, t.name.len);
        const name_short = t.name[0..maxname];

        switch (t.change) {
            .added => {
                const sh = try makeShapeStr(allocator, t.shape_b);
                defer allocator.free(sh);
                const p = try fmtParams(t.params_b, allocator);
                defer allocator.free(p);
                const sh_with_params = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ sh, p });
                defer allocator.free(sh_with_params);
                std.debug.print("   {s} {s:<40} {s:<12} {s:<22} {s:<12} {d:.1}%\n", .{ icon, name_short, clabel, sh_with_params, "—", t.sparsity_b });
            },
            .removed => {
                const sh = try makeShapeStr(allocator, t.shape_a);
                defer allocator.free(sh);
                const p = try fmtParams(t.params_a, allocator);
                defer allocator.free(p);
                const sh_with_params = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ sh, p });
                defer allocator.free(sh_with_params);
                std.debug.print("   {s} {s:<40} {s:<12} {s:<22} {s:<12} {d:.1}%\n", .{ icon, name_short, clabel, sh_with_params, "—", t.sparsity_a });
            },
            .modified, .unchanged => {
                const shape_str = if (!shapeEqual(t.shape_a, t.shape_b)) blk: {
                    const sa = try makeShapeStr(allocator, t.shape_a);
                    defer allocator.free(sa);
                    const sb = try makeShapeStr(allocator, t.shape_b);
                    defer allocator.free(sb);
                    break :blk try std.fmt.allocPrint(allocator, "{s}→{s}", .{ sa, sb });
                } else try makeShapeStr(allocator, t.shape_b);
                defer allocator.free(shape_str);

                const nsign: []const u8 = if (t.norm_delta_pct >= 0) "+" else "";
                const norm_str = try std.fmt.allocPrint(allocator, "{s}{d:.1}%", .{ nsign, t.norm_delta_pct });
                defer allocator.free(norm_str);

                const sp_delta = t.sparsity_b - t.sparsity_a;
                const sp_sign: []const u8 = if (sp_delta >= 0) "+" else "";
                const sp_str = try std.fmt.allocPrint(allocator, "{d:.1}%({s}{d:.1}%)", .{ t.sparsity_b, sp_sign, sp_delta });
                defer allocator.free(sp_str);

                const opaque_type = t.dtype_a == .unknown or t.dtype_b == .unknown;
                const cos_str = if (t.change == .unchanged)
                    try allocator.dupe(u8, "1.0000")
                else if (opaque_type)
                    try allocator.dupe(u8, "n/a")
                else
                    try std.fmt.allocPrint(allocator, "{d:.4}", .{t.cosine_sim});
                defer allocator.free(cos_str);

                std.debug.print("   {s} {s:<40} {s:<12} {s:<22} {s:<12} {s:<12} {s}\n", .{ icon, name_short, clabel, shape_str, norm_str, sp_str, cos_str });

                if (t.quant_label_a.len > 0 and t.quant_label_b.len > 0 and !std.mem.eql(u8, t.quant_label_a, t.quant_label_b)) {
                    std.debug.print("      quantization: {s} → {s}\n", .{ t.quant_label_a, t.quant_label_b });
                } else if (t.quant_label_a.len > 0) {
                    std.debug.print("      quantization: {s}\n", .{t.quant_label_a});
                }
            },
        }
    }

    std.debug.print("\n", .{});

    if (diff.arch_changed) {
        std.debug.print("   ⚠️  Architecture changed — models are NOT backward compatible\n", .{});
    }

    std.debug.print("\n", .{});
}

pub fn printWeightDiffJson(allocator: std.mem.Allocator, diff: *const WeightDiff) !void {
    _ = allocator;
    std.debug.print("{{\n", .{});
    std.debug.print("  \"file_a\": \"{s}\",\n", .{diff.file_a});
    std.debug.print("  \"file_b\": \"{s}\",\n", .{diff.file_b});
    std.debug.print("  \"total_params_a\": {d},\n", .{diff.total_params_a});
    std.debug.print("  \"total_params_b\": {d},\n", .{diff.total_params_b});
    std.debug.print("  \"total_bytes_a\": {d},\n", .{diff.total_bytes_a});
    std.debug.print("  \"total_bytes_b\": {d},\n", .{diff.total_bytes_b});
    std.debug.print("  \"arch_changed\": {s},\n", .{if (diff.arch_changed) "true" else "false"});
    std.debug.print("  \"tensors\": [\n", .{});
    for (diff.tensors, 0..) |t, i| {
        const comma: []const u8 = if (i < diff.tensors.len - 1) "," else "";
        std.debug.print("    {{", .{});
        std.debug.print("\"name\":\"{s}\",", .{t.name});
        std.debug.print("\"change\":\"{s}\",", .{@tagName(t.change)});
        std.debug.print("\"params_a\":{d},", .{t.params_a});
        std.debug.print("\"params_b\":{d},", .{t.params_b});
        std.debug.print("\"norm_a\":{d:.4},", .{t.norm_a});
        std.debug.print("\"norm_b\":{d:.4},", .{t.norm_b});
        std.debug.print("\"norm_delta_pct\":{d:.2},", .{t.norm_delta_pct});
        std.debug.print("\"mean_a\":{d:.6},", .{t.mean_a});
        std.debug.print("\"mean_b\":{d:.6},", .{t.mean_b});
        std.debug.print("\"std_a\":{d:.6},", .{t.std_a});
        std.debug.print("\"std_b\":{d:.6},", .{t.std_b});
        std.debug.print("\"sparsity_a\":{d:.2},", .{t.sparsity_a});
        std.debug.print("\"sparsity_b\":{d:.2},", .{t.sparsity_b});
        std.debug.print("\"cosine_sim\":{d:.6}", .{t.cosine_sim});
        std.debug.print("}}{s}\n", .{comma});
    }
    std.debug.print("  ]\n}}\n", .{});
}

fn needsPython(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".pt") or
        std.mem.endsWith(u8, path, ".pth") or
        std.mem.endsWith(u8, path, ".bin");
}

fn isNpzExt(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".npz");
}

fn isPyTorchExt(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".pt") or
        std.mem.endsWith(u8, path, ".pth") or
        std.mem.endsWith(u8, path, ".bin");
}

pub fn cmdWeightDiff(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_a: []const u8,
    path_b: []const u8,
    show_unchanged: bool,
    format: []const u8,
) !void {
    if (needsPython(path_a) or needsPython(path_b)) {
        std.debug.print("🔍 Comparing {s} vs {s} via Python (torch)...\n\n", .{ path_a, path_b });

        var diff = combinedPythonDiff(io, allocator, path_a, path_b, true) catch |err| {
            std.debug.print("❌ Failed: {}\n\n", .{err});
            std.debug.print("   PyTorch .pt/.pth files require: pip install torch\n\n", .{});
            return;
        };
        defer diff.deinit(allocator);

        if (std.mem.eql(u8, format, "json")) {
            try printWeightDiffJson(allocator, &diff);
        } else {
            try printWeightDiff(allocator, &diff, show_unchanged);
        }
        return;
    }

    std.debug.print("🔍 Parsing {s}...\n", .{path_a});
    var wf_a = parseWeightFile(io, allocator, path_a) catch {
        if (isNpzExt(path_a) or isNpzExt(path_b)) {
            std.debug.print("   (compressed npz — falling back to Python)\n\n", .{});
            var diff = combinedPythonDiff(io, allocator, path_a, path_b, false) catch |err2| {
                std.debug.print("❌ Failed: {}\n\n", .{err2});
                std.debug.print("   Compressed .npz requires: pip install numpy\n\n", .{});
                return;
            };
            defer diff.deinit(allocator);
            if (std.mem.eql(u8, format, "json")) {
                try printWeightDiffJson(allocator, &diff);
            } else {
                try printWeightDiff(allocator, &diff, show_unchanged);
            }
            return;
        }
        std.debug.print("❌ Failed to parse {s}\n\n", .{path_a});
        std.debug.print("   Supported formats:\n", .{});
        std.debug.print("   .safetensors — pure Zig, zero dependencies\n", .{});
        std.debug.print("   .npy         — pure Zig, zero dependencies\n", .{});
        std.debug.print("   .npz         — pure Zig if uncompressed, else needs numpy\n", .{});
        std.debug.print("   .pt .pth     — requires torch\n\n", .{});
        return;
    };
    defer wf_a.deinit(allocator);

    std.debug.print("🔍 Parsing {s}...\n", .{path_b});
    var wf_b = parseWeightFile(io, allocator, path_b) catch {
        if (isNpzExt(path_a) or isNpzExt(path_b)) {
            std.debug.print("   (compressed npz — falling back to Python)\n\n", .{});
            var diff = combinedPythonDiff(io, allocator, path_a, path_b, false) catch |err2| {
                std.debug.print("❌ Failed: {}\n\n", .{err2});
                std.debug.print("   Compressed .npz requires: pip install numpy\n\n", .{});
                return;
            };
            defer diff.deinit(allocator);
            if (std.mem.eql(u8, format, "json")) {
                try printWeightDiffJson(allocator, &diff);
            } else {
                try printWeightDiff(allocator, &diff, show_unchanged);
            }
            return;
        }
        std.debug.print("❌ Failed to parse {s}\n\n", .{path_b});
        return;
    };
    defer wf_b.deinit(allocator);

    std.debug.print("   A: {d} tensors,  {d} params\n", .{ wf_a.tensors.len, wf_a.total_params });
    std.debug.print("   B: {d} tensors,  {d} params\n\n", .{ wf_b.tensors.len, wf_b.total_params });

    const data_a = std.Io.Dir.cwd().readFileAlloc(io, path_a, allocator, .unlimited) catch null;
    defer if (data_a) |d| allocator.free(d);
    const data_b = std.Io.Dir.cwd().readFileAlloc(io, path_b, allocator, .unlimited) catch null;
    defer if (data_b) |d| allocator.free(d);

    var diff = try computeWeightDiff(allocator, &wf_a, &wf_b, data_a, data_b, path_a, path_b);
    defer diff.deinit(allocator);

    if (std.mem.eql(u8, format, "json")) {
        try printWeightDiffJson(allocator, &diff);
    } else {
        try printWeightDiff(allocator, &diff, show_unchanged);
    }
}
fn combinedPythonDiff(
    io: std.Io,
    allocator: std.mem.Allocator,
    path_a: []const u8,
    path_b: []const u8,
    is_pytorch: bool,
) !WeightDiff {
    const script = if (is_pytorch)
        \\import sys, json, torch
        \\pa, pb = sys.argv[1], sys.argv[2]
        \\def load(p):
        \\    try:
        \\        s = torch.load(p, map_location='cpu', weights_only=True)
        \\    except Exception:
        \\        s = torch.load(p, map_location='cpu')
        \\    if hasattr(s, 'state_dict'):
        \\        s = s.state_dict()
        \\    return {k: v for k, v in s.items() if hasattr(v, 'shape')}
        \\A = load(pa)
        \\B = load(pb)
        \\def stats(v):
        \\    f = v.float().flatten()
        \\    n = f.numel()
        \\    return {
        \\        'shape': list(v.shape), 'dtype': str(v.dtype).replace('torch.',''),
        \\        'l2': float(f.norm(2)) if n>0 else 0,
        \\        'mean': float(f.mean()) if n>0 else 0,
        \\        'std': float(f.std()) if n>1 else 0,
        \\        'sparsity': float((f.abs()<1e-6).float().mean())*100, 'n': n}
        \\results = []
        \\keys = set(A.keys()) | set(B.keys())
        \\for k in keys:
        \\    if k in A and k in B:
        \\        sa, sb = stats(A[k]), stats(B[k])
        \\        cos = 1.0
        \\        if sa['shape'] == sb['shape'] and A[k].numel() > 0:
        \\            fa = A[k].float().flatten()
        \\            fb = B[k].float().flatten()
        \\            na, nb = fa.norm(2), fb.norm(2)
        \\            if na > 1e-12 and nb > 1e-12:
        \\                cos = float(torch.dot(fa, fb) / (na * nb))
        \\            else:
        \\                cos = 1.0
        \\        results.append({'name': k, 'change': 'both', 'a': sa, 'b': sb, 'cos': cos})
        \\    elif k in A:
        \\        results.append({'name': k, 'change': 'removed', 'a': stats(A[k])})
        \\    else:
        \\        results.append({'name': k, 'change': 'added', 'b': stats(B[k])})
        \\print(json.dumps(results))
    else
        \\import sys, json, numpy as np
        \\pa, pb = sys.argv[1], sys.argv[2]
        \\A = dict(np.load(pa, allow_pickle=False).items())
        \\B = dict(np.load(pb, allow_pickle=False).items())
        \\def stats(v):
        \\    f = v.astype(np.float64).flatten()
        \\    n = f.size
        \\    return {
        \\        'shape': list(v.shape), 'dtype': str(v.dtype),
        \\        'l2': float(np.linalg.norm(f)) if n>0 else 0,
        \\        'mean': float(f.mean()) if n>0 else 0,
        \\        'std': float(f.std()) if n>1 else 0,
        \\        'sparsity': float(np.mean(np.abs(f)<1e-6))*100, 'n': n}
        \\results = []
        \\keys = set(A.keys()) | set(B.keys())
        \\for k in keys:
        \\    if k in A and k in B:
        \\        sa, sb = stats(A[k]), stats(B[k])
        \\        cos = 1.0
        \\        if sa['shape'] == sb['shape'] and A[k].size > 0:
        \\            fa = A[k].astype(np.float64).flatten()
        \\            fb = B[k].astype(np.float64).flatten()
        \\            na, nb = np.linalg.norm(fa), np.linalg.norm(fb)
        \\            if na > 1e-12 and nb > 1e-12:
        \\                cos = float(np.dot(fa, fb) / (na * nb))
        \\            else:
        \\                cos = 1.0
        \\        results.append({'name': k, 'change': 'both', 'a': sa, 'b': sb, 'cos': cos})
        \\    elif k in A:
        \\        results.append({'name': k, 'change': 'removed', 'a': stats(A[k])})
        \\    else:
        \\        results.append({'name': k, 'change': 'added', 'b': stats(B[k])})
        \\print(json.dumps(results))
    ;

    const tmp_path = if (is_pytorch) "/tmp/zev_pt_diff.py" else "/tmp/zev_npz_diff.py";
    const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    var f_buffer: [8192]u8 = undefined;
    var f_writer = f.writer(io, &f_buffer);
    try f_writer.interface.writeAll(script);
    try f_writer.flush();
    f.close(io);

    var out_buf: [8 * 1024 * 1024]u8 = undefined;
    var n: usize = 0;

    if (std.process.spawn(io, .{
        .argv = &.{ "python3", tmp_path, path_a, path_b },
        .stdout = .pipe,
        .stderr = .ignore,
    })) |child_result| {
        var child = child_result;
        var child_scratch: [4096]u8 = undefined;
        var child_reader = child.stdout.?.reader(io, &child_scratch);
        n = child_reader.interface.readSliceShort(&out_buf) catch 0;
        _ = child.wait(io) catch {};
    } else |_| {}

    if (n == 0) return error.HelperFailed;
    const json_out = out_buf[0..n];

    var diffs = std.ArrayList(TensorDiff).empty;
    var total_a: usize = 0;
    var total_b: usize = 0;
    var bytes_a: usize = 0;
    var bytes_b: usize = 0;
    var arch_changed = false;

    var depth: usize = 0;
    var obj_start: usize = 0;
    var in_str = false;
    var j: usize = 0;
    while (j < json_out.len) : (j += 1) {
        const c = json_out[j];
        if (c == '"' and (j == 0 or json_out[j - 1] != '\\')) in_str = !in_str;
        if (in_str) continue;
        if (c == '{') {
            if (depth == 0) obj_start = j;
            depth += 1;
        }
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                const obj = json_out[obj_start .. j + 1];
                const tname = (try jsonStr(obj, "name", allocator)) orelse continue;
                const change_s = (try jsonStr(obj, "change", allocator)) orelse try allocator.dupe(u8, "both");
                defer allocator.free(change_s);

                if (std.mem.eql(u8, change_s, "added")) {
                    arch_changed = true;
                    const sub = extractSubObj(obj, "\"b\":");
                    const dtype_s = (try jsonStr(sub, "dtype", allocator)) orelse try allocator.dupe(u8, "float32");
                    defer allocator.free(dtype_s);
                    const shape = try jsonShape(sub, "shape", allocator);
                    const n_p = computeParams(shape);
                    const l2 = jsonF64(sub, "\"l2\":");
                    const mn = jsonF64(sub, "\"mean\":");
                    const sd = jsonF64(sub, "\"std\":");
                    const sp = jsonF64(sub, "\"sparsity\":");
                    total_b += n_p;
                    bytes_b += n_p * DType.fromStr(dtype_s).bytesPerElement();
                    try diffs.append(allocator, .{
                        .name = tname,
                        .change = .added,
                        .dtype_a = .unknown,
                        .dtype_b = DType.fromStr(dtype_s),
                        .shape_a = try allocator.alloc(usize, 0),
                        .shape_b = shape,
                        .params_a = 0,
                        .params_b = n_p,
                        .norm_a = 0,
                        .norm_b = l2,
                        .norm_delta_pct = 0,
                        .mean_a = 0,
                        .mean_b = mn,
                        .std_a = 0,
                        .std_b = sd,
                        .sparsity_a = 0,
                        .sparsity_b = sp,
                        .cosine_sim = 0,
                    });
                } else if (std.mem.eql(u8, change_s, "removed")) {
                    arch_changed = true;
                    const sub = extractSubObj(obj, "\"a\":");
                    const dtype_s = (try jsonStr(sub, "dtype", allocator)) orelse try allocator.dupe(u8, "float32");
                    defer allocator.free(dtype_s);
                    const shape = try jsonShape(sub, "shape", allocator);
                    const n_p = computeParams(shape);
                    const l2 = jsonF64(sub, "\"l2\":");
                    const mn = jsonF64(sub, "\"mean\":");
                    const sd = jsonF64(sub, "\"std\":");
                    const sp = jsonF64(sub, "\"sparsity\":");
                    total_a += n_p;
                    bytes_a += n_p * DType.fromStr(dtype_s).bytesPerElement();
                    try diffs.append(allocator, .{
                        .name = tname,
                        .change = .removed,
                        .dtype_a = DType.fromStr(dtype_s),
                        .dtype_b = .unknown,
                        .shape_a = shape,
                        .shape_b = try allocator.alloc(usize, 0),
                        .params_a = n_p,
                        .params_b = 0,
                        .norm_a = l2,
                        .norm_b = 0,
                        .norm_delta_pct = 0,
                        .mean_a = mn,
                        .mean_b = 0,
                        .std_a = sd,
                        .std_b = 0,
                        .sparsity_a = sp,
                        .sparsity_b = 0,
                        .cosine_sim = 0,
                    });
                } else {
                    const sub_a = extractSubObj(obj, "\"a\":");
                    const sub_b = extractSubObj(obj, "\"b\":");
                    const dtype_a_s = (try jsonStr(sub_a, "dtype", allocator)) orelse try allocator.dupe(u8, "float32");
                    defer allocator.free(dtype_a_s);
                    const dtype_b_s = (try jsonStr(sub_b, "dtype", allocator)) orelse try allocator.dupe(u8, "float32");
                    defer allocator.free(dtype_b_s);
                    const shape_a = try jsonShape(sub_a, "shape", allocator);
                    const shape_b = try jsonShape(sub_b, "shape", allocator);
                    const na_p = computeParams(shape_a);
                    const nb_p = computeParams(shape_b);
                    const l2_a = jsonF64(sub_a, "\"l2\":");
                    const l2_b = jsonF64(sub_b, "\"l2\":");
                    const mn_a = jsonF64(sub_a, "\"mean\":");
                    const mn_b = jsonF64(sub_b, "\"mean\":");
                    const sd_a = jsonF64(sub_a, "\"std\":");
                    const sd_b = jsonF64(sub_b, "\"std\":");
                    const sp_a = jsonF64(sub_a, "\"sparsity\":");
                    const sp_b = jsonF64(sub_b, "\"sparsity\":");
                    const cos = jsonF64(obj, "\"cos\":");

                    const same_shape = shapeEqual(shape_a, shape_b);
                    if (!same_shape or !std.mem.eql(u8, dtype_a_s, dtype_b_s)) arch_changed = true;

                    const norm_delta_pct: f64 = if (l2_a > 1e-12) ((l2_b - l2_a) / l2_a) * 100.0 else 0.0;
                    const changed = !same_shape or cos < 0.99999;

                    total_a += na_p;
                    total_b += nb_p;
                    bytes_a += na_p * DType.fromStr(dtype_a_s).bytesPerElement();
                    bytes_b += nb_p * DType.fromStr(dtype_b_s).bytesPerElement();

                    try diffs.append(allocator, .{
                        .name = tname,
                        .change = if (changed) .modified else .unchanged,
                        .dtype_a = DType.fromStr(dtype_a_s),
                        .dtype_b = DType.fromStr(dtype_b_s),
                        .shape_a = shape_a,
                        .shape_b = shape_b,
                        .params_a = na_p,
                        .params_b = nb_p,
                        .norm_a = l2_a,
                        .norm_b = l2_b,
                        .norm_delta_pct = norm_delta_pct,
                        .mean_a = mn_a,
                        .mean_b = mn_b,
                        .std_a = sd_a,
                        .std_b = sd_b,
                        .sparsity_a = sp_a,
                        .sparsity_b = sp_b,
                        .cosine_sim = cos,
                    });
                }
            }
        }
    }

    return WeightDiff{
        .file_a = path_a,
        .file_b = path_b,
        .format_a = if (is_pytorch) .pytorch else .npz,
        .format_b = if (is_pytorch) .pytorch else .npz,
        .tensors = try diffs.toOwnedSlice(allocator),
        .total_params_a = total_a,
        .total_params_b = total_b,
        .total_bytes_a = bytes_a,
        .total_bytes_b = bytes_b,
        .arch_changed = arch_changed,
    };
}

fn extractSubObj(obj: []const u8, key: []const u8) []const u8 {
    const kpos = std.mem.indexOf(u8, obj, key) orelse return "";
    var i = kpos + key.len;
    while (i < obj.len and obj[i] != '{') i += 1;
    if (i >= obj.len) return "";
    const start = i;
    var depth: usize = 0;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '{') depth += 1;
        if (obj[i] == '}') {
            depth -= 1;
            if (depth == 0) return obj[start .. i + 1];
        }
    }
    return obj[start..];
}
fn parseNpyBytes(allocator: std.mem.Allocator, name: []const u8, data: []const u8) !TensorInfo {
    if (data.len < 10) return error.InvalidFormat;
    if (data[0] != 0x93) return error.InvalidFormat;
    if (!std.mem.eql(u8, data[1..6], "NUMPY")) return error.InvalidFormat;

    const hdr_len: usize = std.mem.readInt(u16, data[8..10], .little);
    if (10 + hdr_len > data.len) return error.InvalidFormat;
    const hdr = data[10 .. 10 + hdr_len];

    var dtype: DType = .f32;
    if (std.mem.indexOf(u8, hdr, "'f4'") != null) dtype = .f32;
    if (std.mem.indexOf(u8, hdr, "'f2'") != null) dtype = .f16;
    if (std.mem.indexOf(u8, hdr, "'f8'") != null) dtype = .f64;
    if (std.mem.indexOf(u8, hdr, "'i4'") != null) dtype = .i32;
    if (std.mem.indexOf(u8, hdr, "'i8'") != null) dtype = .i64;
    if (std.mem.indexOf(u8, hdr, "'i1'") != null) dtype = .i8;
    if (std.mem.indexOf(u8, hdr, "'u1'") != null) dtype = .u8;

    var shape = std.ArrayList(usize).empty;
    if (std.mem.indexOf(u8, hdr, "'shape': (")) |sp| {
        var si = sp + 10;
        while (si < hdr.len and hdr[si] != ')') {
            while (si < hdr.len and (hdr[si] == ' ' or hdr[si] == ',')) si += 1;
            if (si < hdr.len and hdr[si] == ')') break;
            const ds = si;
            while (si < hdr.len and hdr[si] >= '0' and hdr[si] <= '9') si += 1;
            if (si > ds) try shape.append(allocator, std.fmt.parseInt(usize, hdr[ds..si], 10) catch 0);
        }
    }

    const tdata = data[10 + hdr_len ..];
    const n_params = computeParams(shape.items);
    const stats = computeStats(tdata, dtype);

    return TensorInfo{
        .name = try allocator.dupe(u8, name),
        .shape = try shape.toOwnedSlice(allocator),
        .dtype = dtype,
        .num_params = n_params,
        .l2_norm = stats.l2,
        .mean = stats.mean,
        .std_dev = stats.std_dev,
        .sparsity = stats.sparsity,
        .data_offset = 10 + hdr_len,
        .data_len = tdata.len,
    };
}

const ZipEntry = struct {
    name: []const u8,
    method: u16,
    comp_size: u32,
    uncomp_size: u32,
    local_offset: u32,
};

fn findEocd(data: []const u8) !usize {
    if (data.len < 22) return error.NotZip;
    const max_back = @min(data.len, 22 + 65536);
    var i: usize = data.len - 22;
    const floor = data.len - max_back;
    while (true) {
        if (data[i] == 0x50 and data[i + 1] == 0x4b and data[i + 2] == 0x05 and data[i + 3] == 0x06) {
            return i;
        }
        if (i == floor) break;
        i -= 1;
    }
    return error.NotZip;
}

fn listZipEntries(allocator: std.mem.Allocator, data: []const u8) ![]ZipEntry {
    const eocd = try findEocd(data);
    const cd_offset: usize = std.mem.readInt(u32, data[eocd + 16 ..][0..4], .little);
    const total_entries: usize = std.mem.readInt(u16, data[eocd + 10 ..][0..2], .little);

    var entries = std.ArrayList(ZipEntry).empty;
    var pos = cd_offset;
    var i: usize = 0;
    while (i < total_entries) : (i += 1) {
        if (pos + 46 > data.len) break;
        if (!(data[pos] == 0x50 and data[pos + 1] == 0x4b and data[pos + 2] == 0x01 and data[pos + 3] == 0x02)) break;

        const method: u16 = std.mem.readInt(u16, data[pos + 10 ..][0..2], .little);
        const comp_size: u32 = std.mem.readInt(u32, data[pos + 20 ..][0..4], .little);
        const uncomp_size: u32 = std.mem.readInt(u32, data[pos + 24 ..][0..4], .little);
        const name_len: usize = std.mem.readInt(u16, data[pos + 28 ..][0..2], .little);
        const extra_len: usize = std.mem.readInt(u16, data[pos + 30 ..][0..2], .little);
        const comment_len: usize = std.mem.readInt(u16, data[pos + 32 ..][0..2], .little);
        const local_offset: u32 = std.mem.readInt(u32, data[pos + 42 ..][0..4], .little);

        const name_start = pos + 46;
        const name = data[name_start .. name_start + name_len];

        try entries.append(allocator, .{
            .name = name,
            .method = method,
            .comp_size = comp_size,
            .uncomp_size = uncomp_size,
            .local_offset = local_offset,
        });

        pos = name_start + name_len + extra_len + comment_len;
    }

    return entries.toOwnedSlice(allocator);
}

fn extractStoredEntry(data: []const u8, entry: ZipEntry) ![]const u8 {
    const lp = entry.local_offset;
    if (lp + 30 > data.len) return error.CorruptZip;
    if (!(data[lp] == 0x50 and data[lp + 1] == 0x4b and data[lp + 2] == 0x03 and data[lp + 3] == 0x04)) return error.CorruptZip;

    const name_len: usize = std.mem.readInt(u16, data[lp + 26 ..][0..2], .little);
    const extra_len: usize = std.mem.readInt(u16, data[lp + 28 ..][0..2], .little);
    const data_start = lp + 30 + name_len + extra_len;
    const data_end = data_start + entry.uncomp_size;
    if (data_end > data.len) return error.CorruptZip;

    return data[data_start..data_end];
}

pub fn parseNpzPureZig(allocator: std.mem.Allocator, data: []const u8) !WeightFile {
    const entries = try listZipEntries(allocator, data);
    defer allocator.free(entries);

    var tensors = std.ArrayList(TensorInfo).empty;
    var total_params: usize = 0;
    var total_bytes: usize = 0;

    for (entries) |entry| {
        if (entry.method != 0) return error.CompressedNpz;
        if (!std.mem.endsWith(u8, entry.name, ".npy")) continue;

        const raw = try extractStoredEntry(data, entry);
        const tname = entry.name[0 .. entry.name.len - 4];
        const info = try parseNpyBytes(allocator, tname, raw);
        total_params += info.num_params;
        total_bytes += info.data_len;
        try tensors.append(allocator, info);
    }

    return WeightFile{
        .format = .npz,
        .tensors = try tensors.toOwnedSlice(allocator),
        .total_params = total_params,
        .total_bytes = total_bytes,
    };
}

pub fn parseNpyFileBytes(allocator: std.mem.Allocator, name_hint: []const u8, data: []const u8) !WeightFile {
    const base = if (std.mem.lastIndexOf(u8, name_hint, "/")) |p| p + 1 else 0;
    const fname = name_hint[base..];
    const name = if (std.mem.lastIndexOf(u8, fname, ".")) |p| fname[0..p] else fname;
    const info = try parseNpyBytes(allocator, name, data);
    const arr = try allocator.alloc(TensorInfo, 1);
    arr[0] = info;
    return WeightFile{
        .format = .npy,
        .tensors = arr,
        .total_params = info.num_params,
        .total_bytes = info.data_len,
    };
}

pub fn parseWeightFileFromBytes(allocator: std.mem.Allocator, path_hint: []const u8, data: []const u8) !WeightFile {
    if (std.mem.endsWith(u8, path_hint, ".safetensors")) return parseSafetensorsBytes(allocator, data);
    if (std.mem.endsWith(u8, path_hint, ".npy")) return parseNpyFileBytes(allocator, path_hint, data);
    if (std.mem.endsWith(u8, path_hint, ".npz")) return parseNpzPureZig(allocator, data);
    if (std.mem.endsWith(u8, path_hint, ".gguf")) return parseGgufBytes(allocator, data);
    return parseSafetensorsBytes(allocator, data) catch
        parseNpyFileBytes(allocator, path_hint, data) catch
        parseGgufBytes(allocator, data) catch
        parseNpzPureZig(allocator, data);
}
const GgufValueType = enum(u32) {
    uint8 = 0,
    int8 = 1,
    uint16 = 2,
    int16 = 3,
    uint32 = 4,
    int32 = 5,
    float32 = 6,
    bool_t = 7,
    string = 8,
    array = 9,
    uint64 = 10,
    int64 = 11,
    float64 = 12,
    _,
};

fn ggufReadString(data: []const u8, pos: *usize) ![]const u8 {
    if (pos.* + 8 > data.len) return error.Truncated;
    const len: usize = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    if (pos.* + len > data.len) return error.Truncated;
    const s = data[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

fn ggufSkipValue(data: []const u8, pos: *usize, vtype: GgufValueType) !void {
    switch (vtype) {
        .uint8, .int8, .bool_t => pos.* += 1,
        .uint16, .int16 => pos.* += 2,
        .uint32, .int32, .float32 => pos.* += 4,
        .uint64, .int64, .float64 => pos.* += 8,
        .string => _ = try ggufReadString(data, pos),
        .array => {
            if (pos.* + 12 > data.len) return error.Truncated;
            const elem_type: GgufValueType = @enumFromInt(std.mem.readInt(u32, data[pos.*..][0..4], .little));
            pos.* += 4;
            const count: usize = std.mem.readInt(u64, data[pos.*..][0..8], .little);
            pos.* += 8;
            var i: usize = 0;
            while (i < count) : (i += 1) try ggufSkipValue(data, pos, elem_type);
        },
        else => return error.UnknownValueType,
    }
}

const GgmlType = struct {
    block_size: usize,
    type_size: usize,
    label: []const u8,
    known: bool,
};

fn ggmlTypeInfo(type_id: u32) GgmlType {
    return switch (type_id) {
        0 => .{ .block_size = 1, .type_size = 4, .label = "F32", .known = true },
        1 => .{ .block_size = 1, .type_size = 2, .label = "F16", .known = true },
        2 => .{ .block_size = 32, .type_size = 18, .label = "Q4_0", .known = true },
        3 => .{ .block_size = 32, .type_size = 20, .label = "Q4_1", .known = true },
        6 => .{ .block_size = 32, .type_size = 22, .label = "Q5_0", .known = true },
        7 => .{ .block_size = 32, .type_size = 24, .label = "Q5_1", .known = true },
        8 => .{ .block_size = 32, .type_size = 34, .label = "Q8_0", .known = true },
        9 => .{ .block_size = 32, .type_size = 40, .label = "Q8_1", .known = true },
        10 => .{ .block_size = 256, .type_size = 84, .label = "Q2_K", .known = true },
        11 => .{ .block_size = 256, .type_size = 110, .label = "Q3_K", .known = true },
        12 => .{ .block_size = 256, .type_size = 144, .label = "Q4_K", .known = true },
        13 => .{ .block_size = 256, .type_size = 176, .label = "Q5_K", .known = true },
        14 => .{ .block_size = 256, .type_size = 210, .label = "Q6_K", .known = true },
        15 => .{ .block_size = 256, .type_size = 292, .label = "Q8_K", .known = true },
        16 => .{ .block_size = 256, .type_size = 66, .label = "IQ2_XXS", .known = false },
        17 => .{ .block_size = 256, .type_size = 74, .label = "IQ2_XS", .known = false },
        18 => .{ .block_size = 256, .type_size = 98, .label = "IQ3_XXS", .known = false },
        19 => .{ .block_size = 256, .type_size = 50, .label = "IQ1_S", .known = false },
        20 => .{ .block_size = 32, .type_size = 18, .label = "IQ4_NL", .known = false },
        21 => .{ .block_size = 256, .type_size = 110, .label = "IQ3_S", .known = false },
        22 => .{ .block_size = 256, .type_size = 82, .label = "IQ2_S", .known = false },
        23 => .{ .block_size = 256, .type_size = 136, .label = "IQ4_XS", .known = false },
        24 => .{ .block_size = 1, .type_size = 1, .label = "I8", .known = true },
        25 => .{ .block_size = 1, .type_size = 2, .label = "I16", .known = true },
        26 => .{ .block_size = 1, .type_size = 4, .label = "I32", .known = true },
        27 => .{ .block_size = 1, .type_size = 8, .label = "I64", .known = true },
        28 => .{ .block_size = 1, .type_size = 8, .label = "F64", .known = true },
        29 => .{ .block_size = 256, .type_size = 56, .label = "IQ1_M", .known = false },
        30 => .{ .block_size = 1, .type_size = 2, .label = "BF16", .known = true },
        else => .{ .block_size = 1, .type_size = 0, .label = "UNKNOWN", .known = false },
    };
}

pub fn parseGgufBytes(allocator: std.mem.Allocator, data: []const u8) !WeightFile {
    if (data.len < 24) return error.InvalidFormat;
    if (!(data[0] == 0x47 and data[1] == 0x47 and data[2] == 0x55 and data[3] == 0x46))
        return error.InvalidFormat;

    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version < 2) return error.UnsupportedVersion;

    var pos: usize = 8;
    const tensor_count: usize = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;
    const kv_count: usize = std.mem.readInt(u64, data[pos..][0..8], .little);
    pos += 8;

    var alignment: usize = 32;

    var kv_i: usize = 0;
    while (kv_i < kv_count) : (kv_i += 1) {
        const key = try ggufReadString(data, &pos);
        if (pos + 4 > data.len) return error.Truncated;
        const vtype: GgufValueType = @enumFromInt(std.mem.readInt(u32, data[pos..][0..4], .little));
        pos += 4;

        if (std.mem.eql(u8, key, "general.alignment") and vtype == .uint32) {
            alignment = std.mem.readInt(u32, data[pos..][0..4], .little);
        }

        try ggufSkipValue(data, &pos, vtype);
    }

    var tensors = std.ArrayList(TensorInfo).empty;
    var total_params: usize = 0;
    var total_bytes: usize = 0;

    const TensorMeta = struct {
        name: []const u8,
        dims: []usize,
        type_id: u32,
        rel_offset: usize,
    };
    var metas = std.ArrayList(TensorMeta).empty;
    defer {
        for (metas.items) |m| allocator.free(m.dims);
        metas.deinit(allocator);
    }

    var t_i: usize = 0;
    while (t_i < tensor_count) : (t_i += 1) {
        const name = try ggufReadString(data, &pos);
        if (pos + 4 > data.len) return error.Truncated;
        const n_dims: usize = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var dims = try allocator.alloc(usize, n_dims);
        var di: usize = 0;
        while (di < n_dims) : (di += 1) {
            if (pos + 8 > data.len) return error.Truncated;
            dims[di] = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
        }

        if (pos + 4 > data.len) return error.Truncated;
        const type_id: u32 = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (pos + 8 > data.len) return error.Truncated;
        const rel_offset: usize = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;

        try metas.append(allocator, .{ .name = name, .dims = dims, .type_id = type_id, .rel_offset = rel_offset });
    }

    const data_start = (pos + alignment - 1) / alignment * alignment;

    for (metas.items) |m| {
        const tinfo = ggmlTypeInfo(m.type_id);
        var n_params: usize = 1;
        for (m.dims) |d| n_params *= d;

        var byte_len: usize = 0;
        if (tinfo.type_size > 0) {
            const n_blocks = (n_params + tinfo.block_size - 1) / tinfo.block_size;
            byte_len = n_blocks * tinfo.type_size;
        }

        const abs_offset = data_start + m.rel_offset;
        var stats = Stats{ .l2 = 0, .mean = 0, .std_dev = 0, .sparsity = 0 };
        if (m.type_id == 0 and abs_offset + byte_len <= data.len) {
            stats = computeF32Stats(data[abs_offset .. abs_offset + byte_len]);
        } else if (m.type_id == 1 and abs_offset + byte_len <= data.len) {
            stats = computeF16Stats(data[abs_offset .. abs_offset + byte_len]);
        }

        total_params += n_params;
        total_bytes += byte_len;

        try tensors.append(allocator, .{
            .name = try allocator.dupe(u8, m.name),
            .shape = try allocator.dupe(usize, m.dims),
            .dtype = if (m.type_id == 0) .f32 else if (m.type_id == 1) .f16 else if (m.type_id == 30) .bf16 else .unknown,
            .num_params = n_params,
            .l2_norm = stats.l2,
            .mean = stats.mean,
            .std_dev = stats.std_dev,
            .sparsity = stats.sparsity,
            .data_offset = abs_offset,
            .data_len = byte_len,
            .quant_label = tinfo.label,
        });
    }

    return WeightFile{
        .format = .gguf,
        .tensors = try tensors.toOwnedSlice(allocator),
        .total_params = total_params,
        .total_bytes = total_bytes,
    };
}

pub fn parseGguf(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !WeightFile {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(data);
    return parseGgufBytes(allocator, data);
}
