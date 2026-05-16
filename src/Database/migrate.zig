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

    // Virtual tables: drop-and-recreate on SQL text mismatch. PRAGMA
    // table_info misses USING fts5(...) options, so compare the stored
    // sqlite_schema.sql directly — SQLite canonicalizes both sides
    // identically, so byte equality works without normalization.
    for (pristine_tables.keys(), pristine_tables.values()) |name, pristine_sql| {
        if (!std.mem.startsWith(u8, pristine_sql, "CREATE VIRTUAL TABLE")) continue;
        const db_sql = db_tables.get(name) orelse continue; // handled by "new tables" loop above
        if (std.mem.eql(u8, pristine_sql, db_sql)) continue;

        changes_made = true;
        log.info("Recreating virtual table '{s}' (SQL changed)", .{name});
        try dropTable(conn, name);
        conn.execNoArgs(pristine_sql) catch return error.CreateTableFailed;
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
        // Virtual tables already drop-and-recreate above on SQL mismatch.
        if (std.mem.startsWith(u8, pristine_sql, "CREATE VIRTUAL TABLE")) continue;
        const pi = try tableInfo(arena, pristine, table_name);
        const di = try tableInfo(arena, conn, table_name);
        const pfks = try foreignKeyList(arena, pristine, table_name);
        const dfks = try foreignKeyList(arena, conn, table_name);
        const cols_eq = tableInfoEql(&pi, &di);
        const fks_eq = foreignKeyListEql(pfks, dfks);
        const body_eq = cols_eq and fks_eq and
            tableBodyEql(pristine_sql, db_tables.get(table_name).?);
        if (!cols_eq or !fks_eq or !body_eq) {
            tables_to_migrate[migrate_count] = .{ .name = table_name, .sql = pristine_sql };
            migrate_count += 1;
        }
    }

    // Fetched up-front so the table-rebuild loop can filter out dependents
    // the pristine schema no longer declares (e.g. an index on a column
    // being dropped). Trying to recreate such a dependent after the rebuild
    // fails because the columns it referenced are gone; the INDEXES /
    // TRIGGERS phases below would drop them anyway.
    const pristine_indexes = try getSchemaEntries(arena, pristine, "index");
    const pristine_triggers = try getSchemaEntries(arena, pristine, "trigger");

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

            // Views that reference this table are separate schema objects
            // (sqlite_schema.tbl_name is the view's own name), so they
            // don't come back from getDependents. If we leave them in
            // place the step-7 rename would try to rewrite the view's
            // SQL against the dropped original and fail. Drop now,
            // recreate verbatim after the rename.
            const referencing_views = try getAllViewsReferencing(arena, conn, table_name);

            // Drop cross-table triggers and referencing views before modifying the table
            for (all_triggers) |trig|
                try dropEntry(conn, "TRIGGER", trig.name);
            for (referencing_views) |view|
                try dropEntry(conn, "VIEW", view.name);

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

            // Step 8: Recreate indexes, triggers, and views.
            // Skip dependents the pristine schema no longer declares —
            // they're about to be dropped by the INDEXES / TRIGGERS phase
            // below and may reference columns that no longer exist. Views
            // aren't managed via a dedicated phase, so recreate them
            // unconditionally.
            for (dependents) |dep| {
                if (std.mem.eql(u8, dep.dep_type, "index") and !pristine_indexes.contains(dep.name)) continue;
                if (std.mem.eql(u8, dep.dep_type, "trigger") and !pristine_triggers.contains(dep.name)) continue;
                conn.execNoArgs(dep.sql) catch |err| {
                    log.err("failed to recreate {s} '{s}': {}", .{ dep.dep_type, dep.name, err });
                    return error.MigrateFailed;
                };
            }
            for (all_triggers) |trig| {
                if (!pristine_triggers.contains(trig.name)) continue;
                conn.execNoArgs(trig.sql) catch |err| {
                    log.err("failed to recreate trigger '{s}': {}", .{ trig.name, err });
                    return error.MigrateFailed;
                };
            }
            // Views aren't schema-owned by any table here (they often live
            // in app bootstrap code, created at runtime), so we always
            // recreate what we dropped rather than cross-checking against
            // a pristine list.
            for (referencing_views) |view| {
                conn.execNoArgs(view.sql) catch |err| {
                    log.err("failed to recreate view '{s}': {}", .{ view.name, err });
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

const ForeignKey = struct {
    table: []const u8,
    from: []const u8,
    to: []const u8,
    on_update: []const u8,
    on_delete: []const u8,
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
        const sql = try arena.dupeSentinel(u8, row.text(1), 0);
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
        const sql = try arena.dupeSentinel(u8, row.text(1), 0);
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
            .sql = try arena.dupeSentinel(u8, row.text(2), 0),
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
                .sql = try arena.dupeSentinel(u8, row.text(1), 0),
            });
        }
    }
    if (rows.err) |err| return err;
    return try list.toOwnedSlice(arena);
}

/// Find all views whose body references a table name. For views,
/// sqlite_schema.tbl_name is the view's own name (not the underlying
/// table), so a simple tbl_name match wouldn't find them. We substring-
/// match against the SQL body, mirroring getAllTriggersReferencing.
fn getAllViewsReferencing(arena: Allocator, conn: zqlite.Conn, table_name: []const u8) ![]Dependent {
    var rows = try conn.rows(
        \\SELECT name, sql FROM sqlite_schema
        \\WHERE type = 'view' AND sql IS NOT NULL
    , .{});
    defer rows.deinit();

    var list: std.ArrayList(Dependent) = .empty;
    while (rows.next()) |row| {
        const sql = try arena.dupe(u8, row.text(1));
        if (std.mem.find(u8, sql, table_name) != null) {
            try list.append(arena, .{
                .dep_type = "view",
                .name = try arena.dupe(u8, row.text(0)),
                .sql = try arena.dupeSentinel(u8, row.text(1), 0),
            });
        }
    }
    if (rows.err) |err| return err;
    return try list.toOwnedSlice(arena);
}

// -- Comparison helpers --

fn foreignKeyList(arena: Allocator, conn: zqlite.Conn, table_name: []const u8) ![]ForeignKey {
    var buf: [256]u8 = undefined;
    const query = std.fmt.bufPrint(&buf, "PRAGMA foreign_key_list({s})", .{table_name}) catch return error.BufOverflow;

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    var list: std.ArrayList(ForeignKey) = .empty;
    while (rows.next()) |row| {
        try list.append(arena, .{
            .table = try arena.dupe(u8, row.text(2)),
            .from = try arena.dupe(u8, row.text(3)),
            .to = try arena.dupe(u8, row.text(4)),
            .on_update = try arena.dupe(u8, row.text(5)),
            .on_delete = try arena.dupe(u8, row.text(6)),
        });
    }
    if (rows.err) |err| return err;
    return try list.toOwnedSlice(arena);
}

fn foreignKeyListEql(lhs: []const ForeignKey, rhs: []const ForeignKey) bool {
    if (lhs.len != rhs.len) return false;
    // PRAGMA foreign_key_list returns FKs in a stable order (by declaration
    // position). A rebuild preserves that order, so positional comparison
    // is sufficient for migrations authored in the normal way.
    for (lhs, rhs) |l, r| {
        if (!std.mem.eql(u8, l.table, r.table)) return false;
        if (!std.mem.eql(u8, l.from, r.from)) return false;
        if (!std.mem.eql(u8, l.to, r.to)) return false;
        if (!std.mem.eql(u8, l.on_update, r.on_update)) return false;
        if (!std.mem.eql(u8, l.on_delete, r.on_delete)) return false;
    }
    return true;
}

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

/// Whether two CREATE TABLE statements have the same body — the column
/// definitions, table constraints, and any trailing modifiers like
/// WITHOUT ROWID / STRICT. Streams both through a tokenizer starting at
/// the first `(`, ignoring whitespace between tokens. Skipping to `(`
/// sidesteps the cosmetic differences SQLite introduces in the prefix:
/// the schematab docs note that stored SQL is normalized (CREATE/TABLE
/// uppercased) and `ALTER TABLE ... RENAME` re-quotes the table name on
/// storage. PRAGMA table_info / foreign_key_list don't expose CHECK
/// clauses, UNIQUE table constraints, or composite PRIMARY KEY — this
/// fills that gap.
fn tableBodyEql(lhs_sql: []const u8, rhs_sql: []const u8) bool {
    var l: SqlTokens = .{ .sql = lhs_sql };
    var r: SqlTokens = .{ .sql = rhs_sql };
    if (!l.skipToBody() or !r.skipToBody()) return false;
    while (true) {
        const lt = l.next();
        const rt = r.next();
        if (lt == null and rt == null) return true;
        if (lt == null or rt == null) return false;
        if (!std.mem.eql(u8, lt.?, rt.?)) return false;
    }
}

/// Minimal SQL tokenizer: word runs ([A-Za-z0-9_]+) and single-char
/// punctuation are each one token; whitespace is the separator.
/// Sufficient for comparing CREATE TABLE bodies side-by-side.
const SqlTokens = struct {
    sql: []const u8,
    i: usize = 0,

    fn skipToBody(self: *SqlTokens) bool {
        while (self.next()) |tok| {
            if (tok.len == 1 and tok[0] == '(') return true;
        }
        return false;
    }

    fn next(self: *SqlTokens) ?[]const u8 {
        while (self.i < self.sql.len and std.ascii.isWhitespace(self.sql[self.i])) self.i += 1;
        if (self.i >= self.sql.len) return null;
        const start = self.i;
        const c = self.sql[self.i];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            while (self.i < self.sql.len) : (self.i += 1) {
                const ch = self.sql[self.i];
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
            }
        } else {
            self.i += 1;
        }
        return self.sql[start..self.i];
    }
};

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
    const sql = std.fmt.bufPrintSentinel(&buf, "DROP TABLE {s}", .{name}, 0) catch return error.BufOverflow;
    try conn.execNoArgs(sql);
}

fn dropEntry(conn: zqlite.Conn, kind: []const u8, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrintSentinel(&buf, "DROP {s} {s}", .{ kind, name }, 0) catch return error.BufOverflow;
    try conn.execNoArgs(sql);
}
