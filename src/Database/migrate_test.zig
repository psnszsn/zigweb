const std = @import("std");
const zqlite = @import("zqlite");
const migrate = @import("migrate.zig");
const tables = @import("tables.zig");

const t = std.testing;

fn openMemory() zqlite.Conn {
    return zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode) catch
        @panic("failed to open in-memory db");
}

fn tableExists(conn: zqlite.Conn, name: []const u8) bool {
    var rows = conn.rows(
        "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?",
        .{name},
    ) catch return false;
    defer rows.deinit();
    return rows.next() != null;
}

test "migrate creates all tables from empty db" {
    const conn = openMemory();
    defer conn.close();

    try migrate.migrateSchema(tables, t.allocator, conn);

    try t.expect(tableExists(conn, "credentials"));
    try t.expect(tableExists(conn, "sessions"));
}

test "migrate is idempotent on current schema" {
    const conn = openMemory();
    defer conn.close();

    conn.execNoArgs("PRAGMA foreign_keys = true") catch unreachable;
    tables.init(conn) catch @panic("failed to init tables");

    try migrate.migrateSchema(tables, t.allocator, conn);
    try migrate.migrateSchema(tables, t.allocator, conn);

    try t.expect(tableExists(conn, "credentials"));
    try t.expect(tableExists(conn, "sessions"));
}

test "migrate drops removed tables" {
    const conn = openMemory();
    defer conn.close();

    conn.execNoArgs("PRAGMA foreign_keys = true") catch unreachable;
    tables.init(conn) catch @panic("failed to init tables");

    conn.execNoArgs("CREATE TABLE IF NOT EXISTS old_stuff (id INTEGER PRIMARY KEY)") catch unreachable;
    try t.expect(tableExists(conn, "old_stuff"));

    try migrate.migrateSchema(tables, t.allocator, conn);

    try t.expect(!tableExists(conn, "old_stuff"));
}

test "migrate rebuilds table when table-level UNIQUE is added" {
    const conn = openMemory();
    defer conn.close();
    conn.execNoArgs("PRAGMA foreign_keys = true") catch unreachable;

    conn.execNoArgs(
        \\CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)
    ) catch unreachable;
    conn.execNoArgs("INSERT INTO foo (id, name) VALUES (1, 'a')") catch unreachable;

    const NewTables = struct {
        pub const foo: tables.Table = .{
            .schema =
            \\CREATE TABLE IF NOT EXISTS foo (id INTEGER PRIMARY KEY, name TEXT, UNIQUE(name))
            ,
        };
    };
    try migrate.migrateSchema(NewTables, t.allocator, conn);

    try conn.execNoArgs("INSERT INTO foo (id, name) VALUES (2, 'b')");
    try t.expectError(error.ConstraintUnique, conn.execNoArgs("INSERT INTO foo (id, name) VALUES (3, 'a')"));
}

test "migrate rebuilds table when CHECK constraint changes" {
    const conn = openMemory();
    defer conn.close();
    conn.execNoArgs("PRAGMA foreign_keys = true") catch unreachable;

    conn.execNoArgs(
        \\CREATE TABLE foo (
        \\  id INTEGER PRIMARY KEY,
        \\  status INTEGER NOT NULL DEFAULT 0 CHECK(status IN (0, 1))
        \\)
    ) catch unreachable;
    conn.execNoArgs("INSERT INTO foo (id, status) VALUES (1, 1)") catch unreachable;

    try t.expectError(error.ConstraintCheck, conn.execNoArgs("INSERT INTO foo (id, status) VALUES (2, 2)"));

    const NewTables = struct {
        pub const foo: tables.Table = .{
            .schema =
            \\CREATE TABLE IF NOT EXISTS foo (
            \\  id INTEGER PRIMARY KEY,
            \\  status INTEGER NOT NULL DEFAULT 0 CHECK(status IN (0, 1, 2))
            \\)
            ,
        };
    };
    try migrate.migrateSchema(NewTables, t.allocator, conn);

    try conn.execNoArgs("INSERT INTO foo (id, status) VALUES (2, 2)");

    var rows = try conn.rows("SELECT id, status FROM foo WHERE id = 1", .{});
    defer rows.deinit();
    const r = rows.next().?;
    try t.expectEqual(@as(i64, 1), r.int(0));
    try t.expectEqual(@as(i64, 1), r.int(1));
}
