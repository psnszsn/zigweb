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
const Queries = @import("Queries.zig");

const log = std.log.scoped(.server);

pub const App = struct {
    auth: *zigweb.Auth,
    db: *Database,
    qs: *Queries,
    auth_qs: *zigweb.Auth.Queries,
    etag: *const [18]u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var db = Database.init(tables, init.gpa, "demo.db");
    defer db.close();

    var mutex: Io.Mutex = .init;

    const is_debug = @import("builtin").mode == .Debug;
    const bypass_login = @import("build_options").bypass_login;
    var auth: zigweb.Auth = undefined;
    auth.init(.{
        .app_name = "ZigWeb Demo",
        .origin = if (is_debug) "http://localhost:8080" else "https://demo.example.com",
        .rp_id = if (is_debug) "localhost" else "demo.example.com",
        .debug_bypass = bypass_login,
        .secure_cookie = !is_debug,
    }, &mutex);

    var qs = db.initQueries(Queries);
    var auth_qs = db.initQueries(zigweb.Auth.Queries);

    if (bypass_login) {
        db.conn.exec("INSERT OR IGNORE INTO credentials (id, cred_id, public_key) VALUES (1, X'00', X'00')", .{}) catch {};
    }

    var etag = zigweb.server.generateEtag(io);

    const app: App = .{
        .auth = &auth,
        .db = &db,
        .qs = &qs,
        .auth_qs = &auth_qs,
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

/// Parsed view of `request.head.target`. The raw form is `<path>[?<query>]`;
/// most handlers want the two halves separately.
pub const Target = struct {
    raw: []const u8,
    path: []const u8,
    query: []const u8,

    pub fn parse(raw: []const u8) Target {
        const q = std.mem.indexOfScalar(u8, raw, '?');
        return .{
            .raw = raw,
            .path = if (q) |i| raw[0..i] else raw,
            .query = if (q) |i| raw[i + 1 ..] else "",
        };
    }
};

fn serveRequest(request: *std.http.Server.Request, io: Io, web_dir: Io.Dir, app: *const App) !void {
    const t = Target.parse(request.head.target);
    const auth_ctx: zigweb.Auth.Ctx = .{ .auth = app.auth, .db = app.db.*, .qs = app.auth_qs };

    // ── Public routes ────────────────────────────────────────────────
    switch (request.head.method) {
        .GET => {
            if (std.mem.eql(u8, t.path, "/style.css")) return zigweb.server.serveFile(request, io, web_dir, "style.css", "text/css; charset=utf-8", app.etag);
            if (std.mem.eql(u8, t.path, "/auth.js")) return zigweb.server.serveFile(request, io, web_dir, "auth.js", "application/javascript; charset=utf-8", app.etag);
            if (std.mem.eql(u8, t.path, "/auth/register-challenge")) return auth_ctx.handleRegisterChallenge(request, io);
            if (std.mem.eql(u8, t.path, "/auth/login-challenge")) return auth_ctx.handleLoginChallenge(request, io);
            if (std.mem.eql(u8, t.path, "/")) return servePage(request, home.home, auth_ctx.getSession(request), io, app);
        },
        .POST => {
            if (std.mem.eql(u8, t.path, "/auth/register")) return auth_ctx.handleRegister(request, io);
            if (std.mem.eql(u8, t.path, "/auth/login")) return auth_ctx.handleLogin(request, io);
            if (std.mem.eql(u8, t.path, "/auth/logout")) return auth_ctx.handleLogout(request, io);
        },
        else => {},
    }

    // ── Auth gate ────────────────────────────────────────────────────
    const session = auth_ctx.getSession(request) orelse {
        return zigweb.server.redirect(request, "/");
    };

    // ── Authenticated routes ─────────────────────────────────────────
    if (std.mem.startsWith(u8, t.path, "/notes")) {
        return notes.handle_request(request, io, app, session, t);
    }
    return zigweb.server.notFound(request);
}

fn servePage(request: *std.http.Server.Request, comptime page: fn (root.Html) anyerror!void, session: ?i64, io: Io, app: *const App) !void {
    var resp: zigweb.server.Response = .{};
    try resp.init(request, .{ .respond_options = zigweb.server.html_page_headers });
    var h = resp.html();
    try root.renderPage(&h, page, session, io, app);
    try resp.end();
}
