const zigweb = @import("zigweb");
const std = @import("std");
const root = @import("root.zig");
const Html = root.Html;
const App = @import("../main.zig").App;

pub fn list(h: Html) !void {
    const credential = h.session orelse return;

    {
        try h.open(.h1, &.{});
        defer h.close(.h1);
        try h.text("Notes");
    }

    // Add note form
    {
        try h.open(.form, &.{ .{ .method = "POST" }, .{ .action = "/notes/add" } });
        defer h.close(.form);

        try h.open(.textarea, &.{ .{ .name = "content" }, .{ .placeholder = "Write a note..." }, .{ .rows = "3" }, .{ .required = true } });
        h.close(.textarea);

        try h.open(.button, &.{.{ .@"type" = "submit" }});
        defer h.close(.button);
        try h.text("Add Note");
    }

    // List notes
    {
        try h.open(.ul, &.{});
        defer h.close(.ul);

        var rows = h.app.qs.list_notes.run(@src(), h.app.db.*, .{ .credential = credential });
        while (rows.next()) |row| {
            try h.open(.li, &.{});
            defer h.close(.li);
            try h.text(row.textNoDupe(.content));
        }
    }
}

pub fn handleAdd(request: *std.http.Server.Request, _: std.Io, app: *const App) !void {
    const session = app.auth.getSession(request) orelse {
        try zigweb.server.redirect(request, "/");
        return;
    };

    var read_buf: [4096]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    const body = readBody(request, &read_buf, &body_buf) orelse {
        try request.respond("Bad Request", .{ .status = .bad_request });
        return;
    };

    const content = parseFormField(body, "content") orelse {
        try request.respond("Missing content", .{ .status = .bad_request });
        return;
    };

    app.qs.insert_note.run(@src(), app.db.*, .{
        .credential = session,
        .content = content,
    });

    try zigweb.server.redirect(request, "/notes");
}

fn readBody(request: *std.http.Server.Request, read_buf: []u8, body_buf: []u8) ?[]const u8 {
    const len = request.head.content_length orelse return null;
    if (len == 0 or len > body_buf.len) return null;
    const n: usize = @intCast(len);
    var reader = request.readerExpectNone(read_buf);
    reader.readSliceAll(body_buf[0..n]) catch return null;
    return body_buf[0..n];
}

fn parseFormField(body: []const u8, field: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], field)) {
                return pair[eq + 1 ..];
            }
        }
    }
    return null;
}
