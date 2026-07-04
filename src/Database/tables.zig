const std = @import("std");
const zqlite = @import("zqlite");

pub const migrate = @import("migrate.zig");

const log = std.log.scoped(.tables);

pub const Table = struct {
    schema: [:0]const u8,
    indexes: []const [:0]const u8 = &.{},
    triggers: []const [:0]const u8 = &.{},
};

/// Initialize tables from any module that has Table-typed declarations.
/// The module should re-export base tables (credentials, sessions) and
/// define its own app-specific tables.
pub fn initTables(comptime Tables: type, conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();

    inline for (comptime std.meta.declarations(Tables)) |decl_name| {
        const table = @field(Tables, decl_name);
        if (@TypeOf(table) != Table) continue;

        errdefer log.err("error creating table {s}", .{decl_name});

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

/// Convenience init for the base tables only.
pub fn init(conn: zqlite.Conn) !void {
    return initTables(@This(), conn);
}

// -- Base table definitions --

pub const credentials: Table = .{
    .schema =
    \\CREATE TABLE IF NOT EXISTS credentials (
    \\  id          INTEGER PRIMARY KEY,
    \\  cred_id     BLOB NOT NULL UNIQUE,
    \\  public_key  BLOB NOT NULL,
    \\  created     INTEGER NOT NULL DEFAULT (unixepoch()),
    \\  last_seen   INTEGER
    \\);
    ,
};

pub const sessions: Table = .{
    .schema =
    \\CREATE TABLE IF NOT EXISTS sessions (
    \\  token       BLOB PRIMARY KEY,
    \\  credential  INTEGER NOT NULL REFERENCES credentials(id),
    \\  created     INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    ,
};
