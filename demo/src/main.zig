const std = @import("std");
const Io = std.Io;
const net = Io.net;
const zigweb = @import("zigweb");
const Html = zigweb.Html;
const Database = zigweb.Database;
const root = @import("app/root.zig");
const home = @import("app/home.zig");
const notes = @import("app/notes.zig");
const tables = @import("tables.zig");

const log = std.log.scoped(.server);

pub const App = struct {
    auth: *zigweb.Auth,
    db: *Database,
    qs: *Queries,
    etag: *const [18]u8,
};

pub const Queries = struct {
    list_notes: Database.Query(
        "SELECT id, content FROM notes WHERE credential = ? ORDER BY created DESC",
        .{ .kind = .rows, .cols = struct { id: i64, content: void }, .args = struct { credential: i64 } },
    ),
    insert_note: Database.Query(
        "INSERT INTO notes (credential, content) VALUES (?, ?)",
        .{ .kind = .exec, .args = struct { credential: i64, content: []const u8 } },
    ),
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var db = Database.init(tables, init.gpa, "demo.db");
    defer db.close();

    var mutex: Io.Mutex = .init;

    const is_debug = @import("builtin").mode == .Debug;
    var auth = zigweb.Auth.init(.{
        .app_name = "ZigWeb Demo",
        .origin = if (is_debug) "http://localhost:8080" else "https://demo.example.com",
        .rp_id = if (is_debug) "localhost" else "demo.example.com",
        .debug_bypass = is_debug,
        .secure_cookie = !is_debug,
    }, &db, &mutex);

    var qs = db.initQueries(Queries);

    if (is_debug) {
        db.conn.exec("INSERT OR IGNORE INTO credentials (id, cred_id, public_key) VALUES (1, X'00', X'00')", .{}) catch {};
    }

    var etag = zigweb.server.generateEtag(io);

    const app: App = .{
        .auth = &auth,
        .db = &db,
        .qs = &qs,
        .etag = &etag,
    };

    // Resolve web root
    var exe_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir_len = try std.process.executableDirPath(io, &exe_dir_buf);
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const web_root = std.fmt.bufPrint(&path_buf, "{s}/../web", .{exe_dir_buf[0..exe_dir_len]}) catch unreachable;
    const web_dir = Io.Dir.cwd().openDir(io, web_root, .{}) catch |err| {
        log.err("Cannot open web root {s}: {}", .{ web_root, err });
        return err;
    };

    const port: u16 = 8080;
    const address: net.IpAddress = .{ .ip4 = .unspecified(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    log.info("Listening on http://localhost:{d}", .{port});

    var g: Io.Group = .init;
    defer g.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.err("Failed to accept: {}", .{err});
            continue;
        };
        g.concurrent(io, accept, .{ io, stream, web_dir, &app }) catch {
            log.warn("concurrency limit reached", .{});
            stream.close(io);
        };
    }
}

fn accept(io: Io, stream: net.Stream, web_dir: Io.Dir, app: *const App) void {
    defer stream.close(io);

    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buf);
    var conn_writer = stream.writer(io, &send_buf);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return,
        };
        serveRequest(&request, io, web_dir, app) catch return;
    }
}

fn serveRequest(request: *std.http.Server.Request, io: Io, web_dir: Io.Dir, app: *const App) !void {
    const target = request.head.target;

    // Static files
    if (std.mem.eql(u8, target, "/style.css")) {
        try zigweb.server.serveFile(request, io, web_dir, "style.css", "text/css; charset=utf-8", app.etag);
        return;
    } else if (std.mem.eql(u8, target, "/auth.js")) {
        try zigweb.server.serveFile(request, io, web_dir, "auth.js", "application/javascript; charset=utf-8", app.etag);
        return;
    }

    // Auth routes
    if (std.mem.eql(u8, target, "/auth/register-challenge")) {
        try app.auth.handleRegisterChallenge(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/register")) {
        try app.auth.handleRegister(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/login-challenge")) {
        try app.auth.handleLoginChallenge(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/login")) {
        try app.auth.handleLogin(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/logout")) {
        try app.auth.handleLogout(request, io);
        return;
    }

    // App routes
    if (std.mem.eql(u8, target, "/")) {
        const session = app.auth.getSession(request);
        try servePage(request, home.home, session, io, app);
    } else if (std.mem.eql(u8, target, "/notes")) {
        const session = app.auth.getSession(request);
        if (session == null) {
            try zigweb.server.redirect(request, "/");
            return;
        }
        try servePage(request, notes.list, session, io, app);
    } else if (std.mem.eql(u8, target, "/notes/add")) {
        try notes.handleAdd(request, io, app);
    } else {
        try zigweb.server.notFound(request);
    }
}

fn servePage(request: *std.http.Server.Request, comptime page: fn (root.Html) anyerror!void, session: ?i64, io: Io, app: *const App) !void {
    var write_buf: [8192]u8 = undefined;
    var body_writer = try request.respondStreaming(&write_buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store, no-cache, must-revalidate" },
                .{ .name = "pragma", .value = "no-cache" },
                .{ .name = "vary", .value = "Cookie" },
            },
        },
    });

    var inner: zigweb.Html = .{ .writer = &body_writer.writer };
    try root.renderPage(&inner, page, session, io, app);
    try body_writer.end();
}
