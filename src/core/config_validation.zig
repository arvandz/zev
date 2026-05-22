const std = @import("std");

pub fn validateEmail(email: []const u8) !void {
    if (email.len == 0) {
        return error.EmptyEmail;
    }

    const at_pos = std.mem.indexOf(u8, email, "@") orelse return error.InvalidEmailFormat;

    if (at_pos == 0) {
        return error.InvalidEmailFormat;
    }

    if (at_pos >= email.len - 1) {
        return error.InvalidEmailFormat;
    }

    const after_at = email[at_pos + 1 ..];
    _ = std.mem.indexOf(u8, after_at, ".") orelse return error.InvalidEmailFormat;
}

pub fn validateStorageBackend(backend: []const u8) !void {
    if (std.mem.eql(u8, backend, "local")) return;
    if (std.mem.eql(u8, backend, "ipfs")) return;
    if (std.mem.eql(u8, backend, "hybrid")) return;

    return error.InvalidStorageBackend;
}

pub fn validateIpfsUrl(url: []const u8) !void {
    if (url.len == 0) {
        return error.EmptyIpfsUrl;
    }

    const has_https = std.mem.startsWith(u8, url, "https://");
    const has_http = std.mem.startsWith(u8, url, "http://");

    if (!has_https and !has_http) {
        return error.InvalidIpfsUrlFormat;
    }

    const protocol_len: usize = if (has_https) 8 else 7;
    const rest = url[protocol_len..];

    if (rest.len == 0) {
        return error.InvalidIpfsUrlFormat;
    }
}

pub fn validateBranchName(name: []const u8) !void {
    if (name.len == 0) {
        return error.EmptyBranchName;
    }

    for (name) |c| {
        if (c <= 32) {
            return error.InvalidBranchName;
        }

        switch (c) {
            '~', '^', ':', '?', '*', '[', '\\', '@', '{', '}' => {
                return error.InvalidBranchName;
            },
            else => {},
        }
    }

    if (name[0] == '.' or name[0] == '/') {
        return error.InvalidBranchName;
    }

    if (name[name.len - 1] == '.' or name[name.len - 1] == '/') {
        return error.InvalidBranchName;
    }

    if (std.mem.indexOf(u8, name, "..") != null) {
        return error.InvalidBranchName;
    }
}

pub fn validateUserName(name: []const u8) !void {
    if (name.len == 0) {
        return error.EmptyUserName;
    }

    if (name.len > 100) {
        return error.UserNameTooLong;
    }
}

pub fn validateBooleanValue(value: []const u8) !void {
    if (std.mem.eql(u8, value, "true")) return;
    if (std.mem.eql(u8, value, "false")) return;

    return error.InvalidBooleanValue;
}

pub fn getErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyEmail => "Email cannot be empty",
        error.InvalidEmailFormat => "Invalid email format. Must be in format: user@example.com",
        error.InvalidStorageBackend => "Invalid storage backend. Must be: local, ipfs, or hybrid",
        error.EmptyIpfsUrl => "IPFS URL cannot be empty",
        error.InvalidIpfsUrlFormat => "Invalid IPFS URL format. Must start with http:// or https://",
        error.EmptyBranchName => "Branch name cannot be empty",
        error.InvalidBranchName => "Invalid branch name. Cannot contain spaces or special characters (~^:?*[\\@{})",
        error.EmptyUserName => "User name cannot be empty",
        error.UserNameTooLong => "User name too long (max 100 characters)",
        error.InvalidBooleanValue => "Invalid boolean value. Must be: true or false",
        else => "Unknown validation error",
    };
}

test "validate email - valid" {
    try validateEmail("user@example.com");
    try validateEmail("test.user@example.co.uk");
}

test "validate email - invalid" {
    try std.testing.expectError(error.InvalidEmailFormat, validateEmail("invalid"));
    try std.testing.expectError(error.InvalidEmailFormat, validateEmail("@example.com"));
    try std.testing.expectError(error.InvalidEmailFormat, validateEmail("user@"));
    try std.testing.expectError(error.EmptyEmail, validateEmail(""));
}

test "validate storage backend" {
    try validateStorageBackend("local");
    try validateStorageBackend("ipfs");
    try validateStorageBackend("hybrid");
    try std.testing.expectError(error.InvalidStorageBackend, validateStorageBackend("invalid"));
}

test "validate IPFS URL" {
    try validateIpfsUrl("http://127.0.0.1:5001");
    try validateIpfsUrl("https://ipfs.io");
    try std.testing.expectError(error.InvalidIpfsUrlFormat, validateIpfsUrl("invalid"));
    try std.testing.expectError(error.EmptyIpfsUrl, validateIpfsUrl(""));
}

test "validate branch name" {
    try validateBranchName("main");
    try validateBranchName("feature/new-feature");
    try validateBranchName("bugfix-123");

    try std.testing.expectError(error.InvalidBranchName, validateBranchName("invalid name"));
    try std.testing.expectError(error.InvalidBranchName, validateBranchName(".invalid"));
    try std.testing.expectError(error.InvalidBranchName, validateBranchName("invalid..name"));
    try std.testing.expectError(error.EmptyBranchName, validateBranchName(""));
}
