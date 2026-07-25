const std = @import("std");

pub fn readAllStdout(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, max_size: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try reader.interface.readSliceShort(&chunk);
        if (bytes_read == 0) break;
        if (buf.items.len + bytes_read > max_size) return error.StreamTooLong;
        try buf.appendSlice(allocator, chunk[0..bytes_read]);
    }

    return try buf.toOwnedSlice(allocator);
}
