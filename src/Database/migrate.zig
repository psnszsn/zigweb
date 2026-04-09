// https://www.sqlite.org/lang_altertable.html
const std = @import("std");
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const tables = @import("tables.zig");

const log = std.log.scoped(.tables);

const StringSet = std.StringArrayHashMapUnmanaged(void);
const StringMap = std.StringArrayHashMapUnmanaged([:0]const u8);
const TableInfo = std.StringArrayHashMapUnmanaged(TableInfoEntry);

/// Migrate the database schema to match the desired state defined by Tables.
/// Tables must be a type whose declarations include Table-typed constants.
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

    var changes_made = false;

    // ====================================
    // TABLES
    // ====================================
    const pristine_tables = try getTables(arena, pristine);
    const db_tables = try getTables(arena, conn);

    // New tables (in pristine but not in db)
    for (pristine_tables.keys(), pristine_tables.values()) |name, sql| {
        if (!db_tables.contains(name)) {
            changes_made = true;
            log.info("Creating new table '{s}'", .{name});
            conn.execNoArgs(sql) catch return error.CreateTableFailed;
        }
    }

    // Removed tables (in db but not in pristine)
    for (db_tables.keys()) |name| {
        if (!pristine_tables.contains(name)) {
            changes_made = true;
            log.info("Dropping table '{s}'", .{name});
            try dropTable(conn, name);
        }
    }

    // If any columns changed, run the 12-step ALTER TABLE procedure.
    // First check if any table actually needs migration.
    var tables_to_migrate: [16]struct { name: []const u8, sql: [:0]const u8 } = undefined;
    var migrate_count: usize = 0;

    for (pristine_tables.keys(), pristine_tables.values()) |table_name, pristine_sql| {
        if (!db_tables.contains(table_name)) continue;
        const pi = try tableInfo(arena, pristine, table_name);
        const di = try tableInfo(arena, conn, table_name);
        if (!tableInfoEql(&pi, &di)) {
            tables_to_migrate[migrate_count] = .{ .name = table_name, .sql = pristine_sql };
            migrate_count += 1;
        }
    }

    for (tables_to_migrate[0..migrate_count]) |entry| {
        const table_name = entry.name;
        const pristine_sql = entry.sql;

        changes_made = true;
        log.info("Migrating table '{s}'", .{table_name});

        const pristine_info = try tableInfo(arena, pristine, table_name);
        const db_info = try tableInfo(arena, conn, table_name);

        for (pristine_info.keys()) |col_name| {
            if (!db_info.contains(col_name))
                log.info("  adding column '{s}'", .{col_name});
        }
        for (db_info.keys()) |col_name| {
            if (!pristine_info.contains(col_name))
                log.info("  dropping column '{s}'", .{col_name});
        }

        // Step 1: Disable foreign key constraints
        conn.execNoArgs("PRAGMA foreign_keys=OFF") catch return error.MigrateFailed;
        defer conn.execNoArgs("PRAGMA foreign_keys=ON") catch {};

        // Step 2: Start a transaction
        try conn.transaction();
        {
            errdefer conn.rollback();

            // Step 3: Remember indexes, triggers, and views associated with table X
            const dependents = try getDependents(arena, conn, table_name);

            // Also collect triggers that reference this table but belong to other tables
            const all_triggers = try getAllTriggersReferencing(arena, conn, table_name);

            // Drop cross-table triggers before modifying the table
            for (all_triggers) |trig|
                try dropEntry(conn, "TRIGGER", trig.name);

            // Step 4: Create new_X with desired schema
            const sql: []const u8 = pristine_sql;
            const idx = std.mem.find(u8, sql, table_name) orelse return error.MigrateFailed;
            const table_x_query = try std.fmt.allocPrintSentinel(arena, "{s}_X{s}", .{
                sql[0 .. idx + table_name.len],
                sql[idx + table_name.len ..],
            }, 0);
            conn.execNoArgs(table_x_query) catch return error.MigrateFailed;

            // Step 5: Transfer content from X into new_X
            const same_columns = try setIntersection(arena, &pristine_info, &db_info);
            const column_list = try std.mem.join(arena, ", ", same_columns.keys());
            const transfer_query = try std.fmt.allocPrintSentinel(arena, "INSERT INTO {s}_X ({s}) SELECT {s} FROM {s}", .{
                table_name, column_list, column_list, table_name,
            }, 0);
            conn.execNoArgs(transfer_query) catch return error.MigrateFailed;

            // Step 6: Drop the old table X
            try dropTable(conn, table_name);

            // Step 7: Rename new_X to X
            const rename_query = try std.fmt.allocPrintSentinel(arena, "ALTER TABLE {s}_X RENAME TO {s}", .{
                table_name, table_name,
            }, 0);
            conn.execNoArgs(rename_query) catch return error.MigrateFailed;

            // Step 8: Recreate indexes, triggers, and views
            for (dependents) |dep| {
                conn.execNoArgs(dep.sql) catch |err| {
                    log.err("failed to recreate {s} '{s}': {}", .{ dep.dep_type, dep.name, err });
                    return error.MigrateFailed;
                };
            }
            for (all_triggers) |trig| {
                conn.execNoArgs(trig.sql) catch |err| {
                    log.err("failed to recreate trigger '{s}': {}", .{ trig.name, err });
                    return error.MigrateFailed;
                };
            }

            // Step 10: Verify foreign key constraints
            var fk_rows = conn.rows("PRAGMA foreign_key_check", .{}) catch return error.MigrateFailed;
            defer fk_rows.deinit();
            if (fk_rows.next()) |row| {
                log.err("foreign key violation: table '{s}', rowid {}", .{ row.text(0), row.int(1) });
                return error.ForeignKeyViolation;
            }
        }

        // Step 11: Commit the transaction
        try conn.commit();
    }

    // ====================================
    // INDEXES
    // ====================================
    const pristine_indexes = try getSchemaEntries(arena, pristine, "index");
    const db_indexes = try getSchemaEntries(arena, conn, "index");

    for (pristine_indexes.keys(), pristine_indexes.values()) |name, sql| {
        if (!db_indexes.contains(name)) {
            changes_made = true;
            log.info("Creating index '{s}'", .{name});
            conn.execNoArgs(sql) catch return error.CreateIndexFailed;
        }
    }

    for (db_indexes.keys()) |name| {
        if (!pristine_indexes.contains(name)) {
            changes_made = true;
            log.info("Dropping index '{s}'", .{name});
            try dropEntry(conn, "INDEX", name);
        }
    }

    // ====================================
    // TRIGGERS
    // ====================================
    const pristine_triggers = try getSchemaEntries(arena, pristine, "trigger");
    const db_triggers = try getSchemaEntries(arena, conn, "trigger");

    for (pristine_triggers.keys(), pristine_triggers.values()) |name, sql| {
        if (!db_triggers.contains(name)) {
            changes_made = true;
            log.info("Creating trigger '{s}'", .{name});
            conn.execNoArgs(sql) catch return error.CreateTriggerFailed;
        }
    }

    for (db_triggers.keys()) |name| {
        if (!pristine_triggers.contains(name)) {
            changes_made = true;
            log.info("Dropping trigger '{s}'", .{name});
            try dropEntry(conn, "TRIGGER", name);
        }
    }

    if (!changes_made)
        log.info("No schema changes needed", .{});
}

// -- Types --

const TableInfoEntry = struct {
    cid: i64,
    col_type: []const u8,
    not_null: bool,
    default_value: ?[]const u8,
    primary_key: bool,
};

const Dependent = struct {
    dep_type: []const u8,
    name: []const u8,
    sql: [:0]const u8,
};

// -- Schema introspection --

fn getTables(arena: Allocator, conn: zqlite.Conn) !StringMap {
    var rows = try conn.rows(
        \\SELECT name, sql FROM sqlite_schema
        \\WHERE type = 'table' AND name != 'sqlite_sequence'
        \\  AND name NOT IN (
        \\    SELECT name FROM pragma_table_list WHERE "type" = 'shadow'
        \\  )
    , .{});
    defer rows.deinit();

    var ret: StringMap = .{};
    while (rows.next()) |row| {
        const name = try arena.dupe(u8, row.text(0));
        const sql = try arena.dupeZ(u8, row.text(1));
        try ret.put(arena, name, sql);
    }
    if (rows.err) |err| return err;
    return ret;
}

fn getSchemaEntries(arena: Allocator, conn: zqlite.Conn, schema_type: []const u8) !StringMap {
    var buf: [128]u8 = undefined;
    const query = std.fmt.bufPrint(
        &buf,
        "SELECT name, sql FROM sqlite_schema WHERE type = '{s}' AND sql IS NOT NULL",
        .{schema_type},
    ) catch return error.BufOverflow;

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    var ret: StringMap = .{};
    while (rows.next()) |row| {
        const name = try arena.dupe(u8, row.text(0));
        const sql = try arena.dupeZ(u8, row.text(1));
        try ret.put(arena, name, sql);
    }
    if (rows.err) |err| return err;
    return ret;
}

fn tableInfo(arena: Allocator, conn: zqlite.Conn, table_name: []const u8) !TableInfo {
    var buf: [256]u8 = undefined;
    const query = std.fmt.bufPrint(&buf, "PRAGMA table_info({s})", .{table_name}) catch return error.BufOverflow;

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    var ret: TableInfo = .{};
    while (rows.next()) |row| {
        const column_name = try arena.dupe(u8, row.text(1));
        const col_type = try arena.dupe(u8, row.text(2));
        const default_value = if (row.nullableText(4)) |t| try arena.dupe(u8, t) else null;
        try ret.put(arena, column_name, .{
            .cid = row.int(0),
            .col_type = col_type,
            .not_null = row.int(3) != 0,
            .default_value = default_value,
            .primary_key = row.int(5) != 0,
        });
    }
    if (rows.err) |err| return err;
    return ret;
}

fn getDependents(arena: Allocator, conn: zqlite.Conn, table_name: []const u8) ![]Dependent {
    var rows = try conn.rows(
        \\SELECT type, name, sql FROM sqlite_schema
        \\WHERE tbl_name = ? AND type IS NOT 'table' AND sql IS NOT NULL
    , .{table_name});
    defer rows.deinit();

    var list: std.ArrayList(Dependent) = .empty;
    while (rows.next()) |row| {
        try list.append(arena, .{
            .dep_type = try arena.dupe(u8, row.text(0)),
            .name = try arena.dupe(u8, row.text(1)),
            .sql = try arena.dupeZ(u8, row.text(2)),
        });
    }
    if (rows.err) |err| return err;
    return try list.toOwnedSlice(arena);
}

/// Find all triggers that reference a table name in their SQL body
/// but are not direct dependents (i.e. tbl_name != table_name).
fn getAllTriggersReferencing(arena: Allocator, conn: zqlite.Conn, table_name: []const u8) ![]Dependent {
    var rows = try conn.rows(
        \\SELECT name, sql FROM sqlite_schema
        \\WHERE type = 'trigger' AND tbl_name != ? AND sql IS NOT NULL
    , .{table_name});
    defer rows.deinit();

    var list: std.ArrayList(Dependent) = .empty;
    while (rows.next()) |row| {
        const sql = try arena.dupe(u8, row.text(1));
        // Only include if the trigger SQL mentions the table being migrated
        if (std.mem.find(u8, sql, table_name) != null) {
            try list.append(arena, .{
                .dep_type = "trigger",
                .name = try arena.dupe(u8, row.text(0)),
                .sql = try arena.dupeZ(u8, row.text(1)),
            });
        }
    }
    if (rows.err) |err| return err;
    return try list.toOwnedSlice(arena);
}

// -- Comparison helpers --

fn tableInfoEql(lhs: *const TableInfo, rhs: *const TableInfo) bool {
    if (lhs.count() != rhs.count()) return false;
    for (lhs.keys()) |column_name| {
        const rhs_entry = rhs.getPtr(column_name) orelse return false;
        const lhs_entry = lhs.getPtr(column_name).?;
        if (!tableInfoEntryEql(lhs_entry, rhs_entry)) return false;
    }
    return true;
}

fn tableInfoEntryEql(lhs: *const TableInfoEntry, rhs: *const TableInfoEntry) bool {
    if (lhs.cid != rhs.cid) return false;
    if (!std.mem.eql(u8, lhs.col_type, rhs.col_type)) return false;
    if (lhs.not_null != rhs.not_null) return false;
    if (lhs.primary_key != rhs.primary_key) return false;
    const ldv = lhs.default_value orelse return rhs.default_value == null;
    const rdv = rhs.default_value orelse return false;
    return std.mem.eql(u8, ldv, rdv);
}

fn setIntersection(arena: Allocator, lhs: *const TableInfo, rhs: *const TableInfo) !StringSet {
    var ret: StringSet = .{};
    for (lhs.keys()) |name|
        if (rhs.contains(name))
            try ret.put(arena, name, {});
    return ret;
}

// -- DDL helpers --

fn dropTable(conn: zqlite.Conn, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "DROP TABLE {s}", .{name}) catch return error.BufOverflow;
    try conn.execNoArgs(sql);
}

fn dropEntry(conn: zqlite.Conn, kind: []const u8, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "DROP {s} {s}", .{ kind, name }) catch return error.BufOverflow;
    try conn.execNoArgs(sql);
}
