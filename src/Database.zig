const Database = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub const tables = @import("Database/tables.zig");
pub const debug_checks = @import("Database/debug_checks.zig");

conn: zqlite.Conn,

/// Open the database and set pragmas. Does not create tables or run migrations.
/// Use `init` for a full setup that also creates tables and migrates.
pub fn open(db_path: [:0]const u8) Database {
    var conn = zqlite.open(db_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode) catch |err| {
        std.debug.print("error opening database: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    errdefer conn.close();

    const db: Database = .{ .conn = conn };
    debug_checks.install(conn);

    conn.execNoArgs(
        \\PRAGMA foreign_keys = true;
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\PRAGMA temp_store = memory;
        \\PRAGMA busy_timeout = 5000;
    ) catch db.fatal(@src());

    return db;
}

/// Open the database, create tables from the given Tables type, and run migrations.
pub fn init(comptime Tables: type, gpa: std.mem.Allocator, db_path: [:0]const u8) Database {
    const db = open(db_path);

    tables.migrate.migrateSchema(Tables, gpa, db.conn) catch |err| {
        std.debug.print("error migrating schema: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    return db;
}

pub fn close(self: Database) void {
    self.conn.close();
}

pub fn fatal(db: Database, src: std.builtin.SourceLocation) noreturn {
    std.debug.panic("{s}:{}: fatal db error: {s}", .{ src.file, src.line, db.conn.lastError() });
}

/// A write transaction, opened by `begin`:
///
///     var tx = try db.begin();
///     defer tx.end(); // rolls back unless committed
///     ...queries run on `tx.db`...
///     try tx.commit();
///
/// `begin` is `BEGIN IMMEDIATE` and only opens a top-level transaction: the
/// writer slot is taken before the first read, so a transaction that reads
/// first can never fail to upgrade (SQLITE_BUSY_SNAPSHOT), and after
/// `commit` the writes are durable and visible to other connections. A
/// helper that runs inside its caller's transaction takes `tx: *const Tx`
/// (it queries on `tx.db` but cannot commit or end it); one that must stay
/// atomic within it opens `tx.savepoint()`, whose commit is only a release.
pub const Tx = struct {
    db: Database,
    nested: bool,
    open: bool = true,

    /// A savepoint inside this transaction: its own `commit`/`end`, undone
    /// with everything else if the enclosing transaction rolls back.
    pub fn savepoint(tx: *const Tx) !Tx {
        assert(tx.open);
        try tx.db.conn.execNoArgs("SAVEPOINT zigweb_tx");
        return .{ .db = tx.db, .nested = true };
    }

    pub fn commit(tx: *Tx) !void {
        assert(tx.open);
        if (tx.nested) try tx.db.conn.execNoArgs("RELEASE zigweb_tx") else try tx.db.conn.commit();
        tx.open = false;
    }

    /// Roll back unless `commit` succeeded. Meant for `defer`.
    pub fn end(tx: *Tx) void {
        if (!tx.open) return;
        tx.open = false;
        if (tx.nested) {
            tx.db.conn.execNoArgs("ROLLBACK TO zigweb_tx") catch {};
            tx.db.conn.execNoArgs("RELEASE zigweb_tx") catch {};
        } else {
            tx.db.conn.rollback();
        }
    }
};

/// Open a top-level write transaction. Inside an open one this is a
/// mistake (its commit would not commit): Debug builds panic, others get
/// `error.TransactionOpen`. Take the caller's `Tx` and use `savepoint`.
pub fn begin(db: Database) !Tx {
    if (zqlite.c.sqlite3_get_autocommit(db.conn.conn) == 0) {
        if (builtin.mode == .debug) std.debug.panic("db.begin() inside an open transaction: take the caller's Tx and use tx.savepoint()", .{});
        return error.TransactionOpen;
    }
    try db.conn.execNoArgs("BEGIN IMMEDIATE");
    return .{ .db = db, .nested = false };
}

/// Initializes a "Queries" type.
/// A Queries type is a struct whose fields are all of type Query.
/// Queries should be deinited when disconnecting from the database.
pub fn initQueries(db: Database, Queries: type) Queries {
    var qs: Queries = undefined;
    const info = @typeInfo(Queries).@"struct";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        @field(qs, name) = FieldType.init(db) catch {
            log.err("Error caused by {s}, query name: {s}", .{
                @typeName(Queries),
                name,
            });
            db.fatal(@src());
        };
    }
    return qs;
}

pub inline fn deinitQueries(_: Database, Queries: type, qs: *const Queries) void {
    inline for (@typeInfo(Queries).@"struct".field_names) |name| {
        @field(qs, name).deinit();
    }
}

fn Result(config: QueryConfig) type {
    return switch (config.kind) {
        .row => ?Rows(config).Row,
        .rows => Rows(config),
        .exec => anyerror!void,
        .returning => @compileError("returning queries must use .runReturning()"),
    };
}

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
        pub const Cols = config.cols;
        pub const Row = Rows(config).Row;

        fn init(db: Database) !@This() {
            const prep = try db.conn.prepare(sql_query);
            return .{ .stmt = @ptrCast(prep.stmt) };
        }

        fn deinit(q: *const @This()) void {
            _ = zqlite.c.sqlite3_finalize(q.stmt);
        }

        /// To be used with '.returning' queries.
        /// Those are INSERT queries that also have a RETURNING clause.
        /// This function will:
        /// - run the query
        /// - assert that it returns one row
        /// - get the specified column value
        /// - reset the sqlite query statement
        /// In particular the early reset is important when this query is
        /// run within a transaction, see #73 for what happens when the
        /// statement is not reset before committing the transaction.
        pub fn runReturning(
            q: *const @This(),
            src: std.builtin.SourceLocation,
            db: Database,
            comptime col: std.meta.FieldEnum(config.cols),
            args: config.args,
        ) ColType(col) {
            if (config.kind != .returning) {
                @compileError("only to be used by .returning queries, use .run() instead");
            }
            const stmt: zqlite.Stmt = .{
                .conn = db.conn.conn,
                .stmt = @ptrCast(q.stmt),
            };

            bind(stmt, db, args);

            const one_row = stmt.step() catch db.fatal(src);
            assert(one_row);

            const r = Rows(config).Row{ .row = .{ .stmt = stmt } };
            defer stmt.reset() catch unreachable;

            const C = ColType(col);
            if (C == void) @compileError("unsupported");
            return r.coerce(C, @intFromEnum(col));
        }

        pub fn run(
            q: *const @This(),
            src: std.builtin.SourceLocation,
            db: Database,
            args: config.args,
        ) Result(config) {
            const stmt: zqlite.Stmt = .{
                .conn = db.conn.conn,
                .stmt = @ptrCast(q.stmt),
            };

            bind(stmt, db, args);

            switch (config.kind) {
                .returning => @compileError("use .runReturning()"),
                .row => {
                    const one_row = stmt.step() catch db.fatal(src);
                    if (!one_row) {
                        stmt.reset() catch db.fatal(src);
                        return null;
                    }
                    return Rows(config).Row{ .row = .{ .stmt = stmt } };
                },
                .rows => {
                    return Rows(config){ .rows = .{ .stmt = stmt, .err = null } };
                },
                .exec => {
                    // Reset so a failed step doesn't poison the next bind().
                    defer stmt.reset() catch {};
                    try stmt.stepToCompletion();
                },
            }
        }

        fn ColType(col: std.meta.FieldEnum(config.cols)) type {
            const c: config.cols = undefined;
            return @TypeOf(@field(c, @tagName(col)));
        }

        fn bind(stmt: zqlite.Stmt, db: Database, args: config.args) void {
            stmt.reset() catch db.fatal(@src());
            switch (parameterMode(stmt)) {
                .positional => {
                    if (!isTuple(config.args)) {
                        std.debug.panic("positional ? SQL parameters require tuple args", .{});
                    }
                    inline for (@typeInfo(config.args).@"struct".field_names, 0..) |name, idx| {
                        bindField(stmt, db, args, name, idx);
                    }
                },
                .named => {
                    if (isTuple(config.args)) {
                        std.debug.panic("named :name SQL parameters require struct args", .{});
                    }
                    validateNamedParameters(stmt, config.args);
                    inline for (@typeInfo(config.args).@"struct".field_names) |name| {
                        const bound = bindNamedArg(stmt, db, args, name);
                        if (bound == 0) {
                            std.debug.panic("named SQL parameter :{s} has no matching placeholder in query", .{name});
                        }
                    }
                },
            }
        }

        const ParameterMode = enum { positional, named };

        fn isTuple(T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct" => |info| blk: {
                    if (info.is_tuple) break :blk true;
                    inline for (info.field_names, 0..) |name, i| {
                        const idx = std.fmt.parseInt(usize, name, 10) catch break :blk false;
                        if (idx != i) break :blk false;
                    }
                    break :blk info.field_names.len != 0 or @sizeOf(T) == 0;
                },
                else => false,
            };
        }

        fn sqliteStmtPtr(stmt: zqlite.Stmt) ?*zqlite.c.sqlite3_stmt {
            return @ptrCast(stmt.stmt);
        }

        fn parameterMode(stmt: zqlite.Stmt) ParameterMode {
            const count = zqlite.c.sqlite3_bind_parameter_count(sqliteStmtPtr(stmt));
            var has_named = false;
            var has_positional = false;
            var i: c_int = 1;
            while (i <= count) : (i += 1) {
                const name_z = zqlite.c.sqlite3_bind_parameter_name(sqliteStmtPtr(stmt), i);
                if (name_z == null) {
                    has_positional = true;
                    continue;
                }
                const name = std.mem.span(name_z);
                switch (name[0]) {
                    ':' => has_named = true,
                    '@', '$' => std.debug.panic("only :name SQL parameters are supported, found {s}", .{name}),
                    '?' => has_positional = true,
                    else => std.debug.panic("unsupported SQL parameter syntax: {s}", .{name}),
                }
            }
            if (has_named and has_positional) {
                std.debug.panic("cannot mix positional ? and named :name SQL parameters in one query", .{});
            }
            return if (has_named) .named else .positional;
        }

        fn validateNamedParameters(stmt: zqlite.Stmt, Args: type) void {
            const count = zqlite.c.sqlite3_bind_parameter_count(sqliteStmtPtr(stmt));
            var i: c_int = 1;
            while (i <= count) : (i += 1) {
                const name_z = zqlite.c.sqlite3_bind_parameter_name(sqliteStmtPtr(stmt), i) orelse continue;
                const name = std.mem.span(name_z);
                if (name.len < 2 or name[0] != ':') {
                    std.debug.panic("only :name SQL parameters are supported, found {s}", .{name});
                }
                if (!hasArgField(Args, name[1..])) {
                    std.debug.panic("named SQL parameter {s} has no matching arg field", .{name});
                }
            }
        }

        fn hasArgField(Args: type, name: []const u8) bool {
            inline for (@typeInfo(Args).@"struct".field_names) |field_name| {
                if (std.mem.eql(u8, field_name, name)) return true;
            }
            return false;
        }

        fn bindNamedArg(stmt: zqlite.Stmt, db: Database, args: config.args, comptime field_name: []const u8) usize {
            var parameter_name: [field_name.len + 2]u8 = undefined;
            parameter_name[0] = ':';
            @memcpy(parameter_name[1 .. 1 + field_name.len], field_name);
            parameter_name[parameter_name.len - 1] = 0;

            var bound: usize = 0;
            const count = zqlite.c.sqlite3_bind_parameter_count(sqliteStmtPtr(stmt));
            var i: c_int = 1;
            while (i <= count) : (i += 1) {
                const name_z = zqlite.c.sqlite3_bind_parameter_name(sqliteStmtPtr(stmt), i) orelse continue;
                if (std.mem.eql(u8, std.mem.span(name_z), parameter_name[0 .. parameter_name.len - 1])) {
                    bindField(stmt, db, args, field_name, @intCast(i - 1));
                    bound += 1;
                }
            }
            return bound;
        }

        /// Bind `args.<name>` to the 0-based parameter `index`.
        fn bindField(stmt: zqlite.Stmt, db: Database, args: config.args, comptime name: []const u8, index: usize) void {
            bindValue(@FieldType(config.args, name), stmt, db, @field(args, name), index);
        }

        fn bindValue(comptime T: type, stmt: zqlite.Stmt, db: Database, value: T, index: usize) void {
            switch (@typeInfo(T)) {
                .@"enum" => stmt.bindValue(@intFromEnum(value), index) catch db.fatal(@src()),
                .optional => |opt| switch (@typeInfo(opt.child)) {
                    .@"enum" => {
                        if (value) |v| {
                            stmt.bindValue(@intFromEnum(v), index) catch db.fatal(@src());
                        } else {
                            stmt.bindValue(null, index) catch db.fatal(@src());
                        }
                    },
                    else => stmt.bindValue(value, index) catch db.fatal(@src()),
                },
                .@"struct" => |info| {
                    if (info.layout != .@"packed" or info.backing_integer == null) {
                        stmt.bindValue(value, index) catch db.fatal(@src());
                        return;
                    }
                    const Int = info.backing_integer.?;
                    const int_value: Int = @bitCast(value);
                    stmt.bindValue(int_value, index) catch db.fatal(@src());
                },
                else => stmt.bindValue(value, index) catch db.fatal(@src()),
            }
        }
    };
}

pub fn Rows(config: QueryConfig) type {
    return struct {
        rows: zqlite.Rows,

        pub fn next(self: *@This()) ?Row {
            return .{ .row = self.rows.next() orelse return null };
        }

        /// Reset the underlying cached stmt so the read-transaction (WAL
        /// snapshot) doesn't stay pinned past this query's scope.
        pub fn deinit(self: *const @This()) void {
            self.rows.stmt.reset() catch {};
        }

        pub const Row = struct {
            row: zqlite.Row,

            /// Reset the underlying cached stmt so the read-transaction (WAL
            /// snapshot) doesn't stay pinned past this row's scope.
            ///
            /// Callers that do SELECT-then-write on the SAME connection must
            /// narrow the `.row` scope (e.g. a block expression) so this
            /// `deinit` fires BEFORE the subsequent write. Otherwise a
            /// concurrent commit on another connection can invalidate the
            /// snapshot and the write fails with SQLITE_BUSY_SNAPSHOT (517),
            /// which `busy_timeout` does not retry.
            pub fn deinit(r: Row) void {
                r.row.stmt.reset() catch {};
            }

            pub fn get(r: Row, comptime col: std.meta.FieldEnum(config.cols)) ColType(col) {
                const C = ColType(col);
                if (C == void) {
                    @compileError("column doesn't specify type, use .getAs()");
                }
                return r.coerce(C, @intFromEnum(col));
            }

            pub fn getAs(r: Row, T: type, comptime col: std.meta.FieldEnum(config.cols)) T {
                const C = ColType(col);
                if (C != void) {
                    @compileError("column has a specified type, use .get()");
                }
                return r.coerce(T, @intFromEnum(col));
            }

            pub fn textNoDupe(r: Row, col: std.meta.FieldEnum(config.cols)) []const u8 {
                return r.row.text(@intFromEnum(col));
            }

            pub fn text(r: Row, allocator: std.mem.Allocator, col: std.meta.FieldEnum(config.cols)) ![]u8 {
                return allocator.dupe(u8, r.row.text(@intFromEnum(col)));
            }

            fn coerce(r: Row, T: type, idx: usize) T {
                return switch (@typeInfo(T)) {
                    .int => @intCast(r.row.int(idx)),
                    .float => @floatCast(r.row.float(idx)),
                    .bool => r.row.boolean(idx),
                    .@"enum" => @enumFromInt(r.row.int(idx)),
                    .optional => |opt| r.coerceOptional(opt.child, idx),
                    .pointer => switch (T) {
                        []u8, []const u8 => @compileError("use textNoDupe()"),
                        else => @compileError("type " ++ @typeName(T) ++ " not supported"),
                    },
                    else => @compileError("type " ++ @typeName(T) ++ " not supported"),
                };
            }

            fn coerceOptional(r: Row, Child: type, idx: usize) ?Child {
                return switch (@typeInfo(Child)) {
                    .int => {
                        const value = r.row.nullableInt(idx) orelse return null;
                        return @intCast(value);
                    },
                    .float => {
                        const value = r.row.nullableFloat(idx) orelse return null;
                        return @floatCast(value);
                    },
                    .bool => return r.row.nullableBoolean(idx),
                    .@"enum" => {
                        const value = r.row.nullableInt(idx) orelse return null;
                        return @enumFromInt(value);
                    },
                    else => @compileError("type ?" ++ @typeName(Child) ++ " not supported"),
                };
            }

            fn ColType(col: std.meta.FieldEnum(config.cols)) type {
                const c: config.cols = undefined;
                return @TypeOf(@field(c, @tagName(col)));
            }
        };
    };
}
