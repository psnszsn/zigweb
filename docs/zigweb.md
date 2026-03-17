# zigweb — Shared Zig Web Infrastructure Library

*2026-03-15T15:28:04Z by Showboat 0.6.1*
<!-- showboat-id: d05ea5fa-b248-4520-829f-d6e3550d8a83 -->

zigweb is a shared Zig library extracted from two web applications (rssbox and progsys) that had ~90% identical infrastructure. It provides: Database (SQLite wrapper with auto-migration), Html (streaming HTML builder), auth (WebAuthn/passkey authentication), and server utilities (static file serving, redirects, etag generation).

## Project structure

```bash
find . -path './.git' -prune -o -path './zig-pkg' -prune -o -path './.zig-cache' -prune -o -path './demo/zig-pkg' -prune -o -path './demo/.zig-cache' -prune -o -path './demo/zig-out' -prune -o -path './demo/demo.db*' -prune -o -name '*.o' -prune -o -name '*.h' -prune -o -name 'zigweb.md' -prune -o -type f -print | sort
```

```output
./.gitignore
./build.zig
./build.zig.zon
./demo/build.zig
./demo/build.zig.zon
./demo/src/app/home.zig
./demo/src/app/notes.zig
./demo/src/app/root.zig
./demo/src/main.zig
./demo/src/tables.zig
./demo/web/style.css
./src/Database.zig
./src/Database/migrate.zig
./src/Database/migrate_test.zig
./src/Database/tables.zig
./src/Html.zig
./src/auth.zig
./src/root.zig
./src/server.zig
./web/auth.js
```

## Library internals

### Module exports (src/root.zig)

root.zig re-exports all public modules so consumers just `@import("zigweb")`.

```bash
cat src/root.zig
```

```output
pub const Database = @import("Database.zig");
pub const tables = @import("Database/tables.zig");
pub const migrate = @import("Database/migrate.zig");
pub const Html = @import("Html.zig");
pub const auth = @import("auth.zig");
pub const server = @import("server.zig");
```

### Database (src/Database.zig)

SQLite wrapper with compile-time query validation. Key public API: `open()` for connection+pragmas only, `init()` for full setup with table creation and migration, `Query()` for type-safe prepared statements, `Rows` iterator, and `initQueries()` to batch-prepare all queries in a struct.

```bash
sed -n '1,4p; /^pub fn open/,/^}/p; /^pub fn init/,/^}/p' src/Database.zig
```

```output
const Database = @This();
const std = @import("std");
const assert = std.debug.assert;
const zqlite = @import("zqlite");
pub fn open(db_path: [:0]const u8) Database {
    var conn = zqlite.open(db_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode) catch |err| {
        std.debug.print("error opening database: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    errdefer conn.close();

    const db: Database = .{ .conn = conn };

    conn.execNoArgs(
        \\PRAGMA locking_mode = EXCLUSIVE;
        \\PRAGMA foreign_keys = true;
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\PRAGMA temp_store = memory;
    ) catch db.fatal(@src());

    return db;
}
pub fn init(comptime Tables: type, gpa: std.mem.Allocator, db_path: [:0]const u8) Database {
    const db = open(db_path);

    tables.initTables(Tables, db.conn) catch {
        std.debug.print("error creating tables\n", .{});
        std.process.exit(1);
    };

    tables.migrate.migrateSchema(Tables, gpa, db.conn) catch |err| {
        std.debug.print("error migrating schema: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    return db;
}
pub fn initQueries(db: Database, Queries: type) Queries {
    var qs: Queries = undefined;
    inline for (@typeInfo(Queries).@"struct".fields) |f| {
        @field(qs, f.name) = f.type.init(db) catch {
            log.err("Error caused by {s}, query name: {s}", .{
                @typeName(Queries),
                f.name,
            });
            db.fatal(@src());
        };
    }
    return qs;
}
```

The `Query()` function generates type-safe prepared statements at comptime. It takes an SQL string and a config specifying `.kind` (.returning, .row, .rows, .exec), `.cols` (result column struct), and `.args` (parameter struct). `initQueries()` batch-prepares all queries in a struct.

```bash
sed -n '91,107p' src/Database.zig
```

```output
const QueryConfig = struct {
    kind: enum { returning, row, rows, exec },
    cols: type = struct {},
    args: type = struct {},
};

pub fn Query(sql_query: [:0]const u8, config: QueryConfig) type {
    return struct {
        stmt: *zqlite.c.sqlite3_stmt,

        pub const cfg = config;
        pub const sql = sql_query;

        fn init(db: Database) !@This() {
            const prep = try db.conn.prepare(sql_query);
            return .{ .stmt = @ptrCast(prep.stmt) };
        }
```

### Tables (src/Database/tables.zig)

Defines the `Table` struct for declarative schema definitions and `initTables()` which iterates comptime declarations to CREATE TABLE for each. The library provides `credentials` and `sessions` tables for auth; apps add their own tables alongside.

```bash
sed -n '8,12p; 17,41p' src/Database/tables.zig
```

```output
pub const Table = struct {
    schema: [:0]const u8,
    indexes: []const [:0]const u8 = &.{},
    triggers: []const [:0]const u8 = &.{},
};
pub fn initTables(comptime Tables: type, conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();

    inline for (comptime std.meta.declarations(Tables)) |d| {
        const table = @field(Tables, d.name);
        if (@TypeOf(table) != Table) continue;

        errdefer log.err("error creating table {s}", .{d.name});

        try conn.execNoArgs(table.schema);

        for (table.indexes, 0..) |index, i| {
            errdefer log.err("error creating index #{}", .{i});
            conn.execNoArgs(index) catch return error.IndexCreationFailed;
        }

        for (table.triggers, 0..) |trigger, i| {
            errdefer log.err("error creating trigger #{}", .{i});
            conn.execNoArgs(trigger) catch return error.TriggerCreationFailed;
        }
    }

    try conn.commit();
}
```

The base table schemas (credentials and sessions) are defined at the bottom of tables.zig. Apps re-export these and add their own — see the demo app's tables.zig below.

### Migration (src/Database/migrate.zig)

Auto-migration using SQLite's 12-step ALTER TABLE procedure. `migrateSchema()` takes a comptime `Tables` type, creates a pristine in-memory DB from those table definitions, diffs it against the actual schema, and applies ALTER TABLE / recreate operations as needed. Handles column additions, removals, type changes, and index/trigger updates.

```bash
sed -n '15,26p' src/Database/migrate.zig
```

```output
pub fn migrateSchema(comptime Tables: type, gpa: Allocator, conn: zqlite.Conn) !void {
    var arena_alloc: std.heap.ArenaAllocator = .init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    // Create pristine in-memory DB with desired schema
    const pristine = zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode) catch
        return error.PristineOpenFailed;
    defer pristine.close();

    pristine.execNoArgs("PRAGMA foreign_keys = true") catch return error.PristinePragmaFailed;
    tables.initTables(Tables, pristine) catch return error.PristineInitFailed;
```

### Auth (src/auth.zig)

WebAuthn/FIDO2 passkey authentication. Parameterized via `Config` struct and `init()` — the app provides origin, RP ID, app name, and flags. Handles registration challenges, credential verification (ECDSA P-256), login challenges, session cookies, and logout. Uses CBOR for attestation parsing.

```bash
sed -n '14,30p; 56,63p; 64,65p; 96,97p; 251,252p; 283,284p; 485,486p; 502,503p' src/auth.zig
```

```output
pub const Config = struct {
    app_name: []const u8,
    origin: []const u8,
    rp_id: []const u8,
    debug_bypass: bool = false,
    secure_cookie: bool = true,
};

var config: Config = undefined;
var db_ref: *Database = undefined;
var mutex_ref: *Io.Mutex = undefined;

const ChallengeList = std.ArrayList([32]u8);

var challenge_buf: [max_pending][32]u8 = undefined;
var pending_challenges: ChallengeList = .empty;

pub fn init(cfg: Config, db: *Database, mtx: *Io.Mutex) void {
    config = cfg;
    db_ref = db;
    mutex_ref = mtx;
    pending_challenges = ChallengeList.initBuffer(&challenge_buf);
    qs = db.initQueries(Queries);
}

pub fn handleRegisterChallenge(request: *std.http.Server.Request, io: Io) !void {
    var challenge: [32]u8 = undefined;
pub fn handleRegister(request: *std.http.Server.Request, io: Io) !void {
    var read_buf: [4096]u8 = undefined;
pub fn handleLoginChallenge(request: *std.http.Server.Request, io: Io) !void {
    var challenge: [32]u8 = undefined;
pub fn handleLogin(request: *std.http.Server.Request, io: Io) !void {
    var read_buf: [4096]u8 = undefined;
pub fn handleLogout(request: *std.http.Server.Request, _: Io) !void {
    const token = parseSessionToken(request);
pub fn getSession(request: *std.http.Server.Request) ?i64 {
    if (config.debug_bypass) return 1;
```

### Server utilities (src/server.zig)

Stateless HTTP helpers: ETag-based static file serving with 304 support, redirects, 404 responses, and URL path parsing.

```bash
sed -n '/^pub fn/p' src/server.zig
```

```output
pub fn generateEtag(io: Io) [18]u8 {
pub fn serveFile(request: *std.http.Server.Request, io: Io, dir: Io.Dir, path: []const u8, content_type: []const u8, etag: *const [18]u8) !void {
pub fn serveFileCached(request: *std.http.Server.Request, io: Io, dir: Io.Dir, path: []const u8, content_type: []const u8, etag: *const [18]u8) !void {
pub fn redirect(request: *std.http.Server.Request, location: []const u8) !void {
pub fn notFound(request: *std.http.Server.Request) !void {
pub fn parseTrailingId(target: []const u8, prefix: []const u8) ?i64 {
```

### Html builder (src/Html.zig)

Streaming HTML writer that outputs directly to an `std.http.Server.Response.Writer`. Provides type-safe tag and attribute methods. This is the superset of all tags/attrs used across both rssbox and progsys — unused ones cost nothing at compile time.

```bash
sed -n '1,6p; 9p; 10,11p; 50,52p; 66p; 67,68p; 123,148p' src/Html.zig
```

```output
const Html = @This();
const std = @import("std");
const Writer = std.Io.Writer;

writer: *Writer,

pub const Tag = enum {
    html,
    head,
    small,

    pub fn str(self: Tag) []const u8 {
pub const Attr = union(enum) {
    class: []const u8,
    id: []const u8,
// -- Element API --

pub fn open(h: *Html, tag: Tag, attrs: []const Attr) !void {
    try h.writer.print("<{s}", .{tag.str()});
    for (attrs) |attr| {
        try attr.write(h.writer);
    }
    if (tag.isVoid()) {
        try h.writer.writeAll(" />");
    } else {
        try h.writer.writeAll(">");
    }
}

pub fn close(h: *Html, tag: Tag) void {
    if (tag.isVoid()) return;
    h.writer.print("</{s}>", .{tag.str()}) catch |err| {
        std.log.err("Html.close({s}): {}", .{ tag.str(), err });
    };
}

pub fn text(h: *Html, s: []const u8) !void {
    try escapeText(h.writer, s);
}

pub fn raw(h: *Html, s: []const u8) !void {
```

### Build system (build.zig)

The library exposes a single "zigweb" module with zqlite and cbor as transitive dependencies. It also provides a `check` step for compile verification and a `test` step for migration tests.

```bash
sed -n '10,24p' build.zig
```

```output
    // Library module (for consumption by other packages)
    const zigweb_mod = b.addModule("zigweb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigweb_mod.addImport("cbor", cbor_dep.module("cbor"));
    zigweb_mod.addImport("zqlite", zqlite_dep.module("zqlite"));

    // zig build check -- verify all library code compiles
    const lib = b.addObject(.{
        .name = "zigweb",
        .root_module = zigweb_mod,
    });
    b.step("check", "Check compilation").dependOn(&lib.step);
```

## How to use zigweb (demo app)

The `demo/` directory contains a minimal notes app that exercises the full library. It shows the integration pattern: declare tables extending the base ones, define queries, init auth with a config, wire routes, and render pages with Html.

### Dependency setup (demo/build.zig.zon)

```bash
sed -n '4,6p' demo/build.zig.zon
```

```output
    .dependencies = .{
        .zigweb = .{ .path = ".." },
    },
```

### Build file (demo/build.zig)

The build imports zigweb as a dependency, adds it to the server module, and installs auth.js from the zigweb package.

```bash
sed -n '7,14p; 23,24p' demo/build.zig
```

```output
    const zigweb_dep = b.dependency("zigweb", .{ .target = target, .optimize = optimize });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("zigweb", zigweb_dep.module("zigweb"));
    b.installFile("web/style.css", "web/style.css");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(zigweb_dep.path("web/auth.js"), .prefix, "web/auth.js").step);
```

### Extending tables (demo/src/tables.zig)

The app re-exports base tables from zigweb and adds its own. The comptime `initTables` iterates all declarations of type `Table` in this module.

```bash
sed -n '1,9p; 12,21p' demo/src/tables.zig
```

```output
const zigweb = @import("zigweb");

pub const migrate = zigweb.tables.migrate;
pub const Table = zigweb.tables.Table;
pub const initTables = zigweb.tables.initTables;

// Re-export base tables
pub const credentials = zigweb.tables.credentials;
pub const sessions = zigweb.tables.sessions;
pub const notes: Table = .{
    .schema =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\  id          INTEGER PRIMARY KEY,
    \\  credential  INTEGER NOT NULL REFERENCES credentials(id),
    \\  content     TEXT NOT NULL DEFAULT '',
    \\  created     INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    ,
};
```

### Application main (demo/src/main.zig)

The main file shows the integration pattern: define queries as typed structs, init the database with the app's tables module, configure auth, generate an etag, resolve the web root, and start the accept loop. Route dispatch is a simple if-else chain.

```bash
sed -n '1,10p; 19,31p' demo/src/main.zig
```

```output
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

pub var qs: Queries = undefined;

```

```bash
sed -n '35,53p' demo/src/main.zig
```

```output
    db = Database.init(tables, init.gpa, "demo.db");
    defer db.close();

    const is_debug = @import("builtin").mode == .Debug;
    zigweb.auth.init(.{
        .app_name = "ZigWeb Demo",
        .origin = if (is_debug) "http://localhost:8080" else "https://demo.example.com",
        .rp_id = if (is_debug) "localhost" else "demo.example.com",
        .debug_bypass = is_debug,
        .secure_cookie = !is_debug,
    }, &db, &mutex);

    qs = db.initQueries(Queries);

    if (is_debug) {
        db.conn.exec("INSERT OR IGNORE INTO credentials (id, cred_id, public_key) VALUES (1, X'00', X'00')", .{}) catch {};
    }

    etag = zigweb.server.generateEtag(io);
```

Route dispatch maps URLs to static files (via `zigweb.server.serveFile`), auth endpoints (via `zigweb.auth.handle*`), and app pages:

```bash
sed -n '105,151p' demo/src/main.zig
```

```output
fn serveRequest(request: *std.http.Server.Request, io: Io, web_dir: Io.Dir) !void {
    const target = request.head.target;

    // Static files
    if (std.mem.eql(u8, target, "/style.css")) {
        try zigweb.server.serveFile(request, io, web_dir, "style.css", "text/css; charset=utf-8", &etag);
        return;
    } else if (std.mem.eql(u8, target, "/auth.js")) {
        try zigweb.server.serveFile(request, io, web_dir, "auth.js", "application/javascript; charset=utf-8", &etag);
        return;
    }

    // Auth routes
    if (std.mem.eql(u8, target, "/auth/register-challenge")) {
        try zigweb.auth.handleRegisterChallenge(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/register")) {
        try zigweb.auth.handleRegister(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/login-challenge")) {
        try zigweb.auth.handleLoginChallenge(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/login")) {
        try zigweb.auth.handleLogin(request, io);
        return;
    } else if (std.mem.eql(u8, target, "/auth/logout")) {
        try zigweb.auth.handleLogout(request, io);
        return;
    }

    // App routes
    if (std.mem.eql(u8, target, "/")) {
        const session = zigweb.auth.getSession(request);
        try servePage(request, home.home, session, io);
    } else if (std.mem.eql(u8, target, "/notes")) {
        const session = zigweb.auth.getSession(request);
        if (session == null) {
            try zigweb.server.redirect(request, "/");
            return;
        }
        try servePage(request, notes.list, session, io);
    } else if (std.mem.eql(u8, target, "/notes/add")) {
        try notes.handleAdd(request, io);
    } else {
        try zigweb.server.notFound(request);
    }
}
```

## Verification

Library compiles and tests pass:

```bash
zig build check 2>&1 && echo 'check: OK'
```

```output
check: OK
```

```bash
zig build test 2>&1 && echo 'test: OK'
```

```output
test: OK
```

```bash
cd demo && zig build 2>&1 && echo 'demo build: OK'
```

```output
demo build: OK
```
