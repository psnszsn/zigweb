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
