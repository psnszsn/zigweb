const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.server);

/// Generate an etag value from random bytes.
/// Returns a quoted 16-character hex string suitable for HTTP ETag headers.
pub fn generateEtag(io: Io) [18]u8 {
    const source = std.Random.IoSource{ .io = io };
    return .{'"'} ++ std.fmt.hex(source.interface().int(u64)) ++ .{'"'};
}

/// Serve a static file with no-cache policy.
pub fn serveFile(request: *std.http.Server.Request, io: Io, dir: Io.Dir, path: []const u8, content_type: []const u8, etag: *const [18]u8) !void {
    return serveFileInner(request, io, dir, path, content_type, "public, no-cache", etag);
}

/// Serve a static file with long-lived cache (24h).
pub fn serveFileCached(request: *std.http.Server.Request, io: Io, dir: Io.Dir, path: []const u8, content_type: []const u8, etag: *const [18]u8) !void {
    return serveFileInner(request, io, dir, path, content_type, "public, max-age=86400", etag);
}

fn serveFileInner(request: *std.http.Server.Request, io: Io, dir: Io.Dir, path: []const u8, content_type: []const u8, cache_control: []const u8, etag: *const [18]u8) !void {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "if-none-match")) {
            if (std.mem.indexOf(u8, header.value, etag[0..18]) != null) {
                try request.respond("", .{ .status = .not_modified });
                return;
            }
        }
    }

    var file = dir.openFile(io, path, .{}) catch |err| {
        log.warn("open {s}: {}", .{ path, err });
        try request.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
        return;
    };
    defer file.close(io);

    const stat = try file.stat(io);

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = cache_control },
        .{ .name = "etag", .value = etag },
    };

    var write_buf: [8192]u8 = undefined;
    var body_writer = try request.respondStreaming(&write_buf, .{
        .content_length = stat.size,
        .respond_options = .{
            .extra_headers = &headers,
        },
    });

    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    _ = try file_reader.interface.streamRemaining(&body_writer.writer);
    try body_writer.end();
}

/// Send a 303 See Other redirect.
pub fn redirect(request: *std.http.Server.Request, location: []const u8) !void {
    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
        },
    });
}

/// Send a 404 Not Found response.
pub fn notFound(request: *std.http.Server.Request) !void {
    try request.respond("Not Found", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}

/// Parse a numeric ID from the end of a URL path.
/// e.g. parseTrailingId("/feeds/remove/42", "/feeds/remove/") returns 42.
pub fn parseTrailingId(target: []const u8, prefix: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const id_str = target[prefix.len..];
    return std.fmt.parseInt(i64, id_str, 10) catch null;
}
