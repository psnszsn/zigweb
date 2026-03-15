const Database = @This();
const std = @import("std");
const assert = std.debug.assert;
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub const tables = @import("Database/tables.zig");

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

    conn.execNoArgs(
        \\PRAGMA locking_mode = EXCLUSIVE;
        \\PRAGMA foreign_keys = true;
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\PRAGMA temp_store = memory;
    ) catch db.fatal(@src());

    return db;
}

/// Open the database, create tables from the given Tables type, and run migrations.
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

pub fn close(self: Database) void {
    self.conn.close();
}

pub fn fatal(db: Database, src: std.builtin.SourceLocation) noreturn {
    std.debug.panic("{s}:{}: fatal db error: {s}", .{ src.file, src.line, db.conn.lastError() });
}

/// Initializes a "Queries" type.
/// A Queries type is a struct whose fields are all of type Query.
/// Queries should be deinited when disconnecting from the database.
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

pub inline fn deinitQueries(_: Database, Queries: type, qs: *const Queries) void {
    inline for (@typeInfo(Queries).@"struct".fields) |f| {
        @field(qs, f.name).deinit();
    }
}

fn Result(config: QueryConfig) type {
    return switch (config.kind) {
        .row => ?Rows(config).Row,
        .rows => Rows(config),
        .exec => void,
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
                    if (!one_row) return null;
                    return Rows(config).Row{ .row = .{ .stmt = stmt } };
                },
                .rows => {
                    return Rows(config){ .rows = .{ .stmt = stmt, .err = null } };
                },
                .exec => {
                    stmt.stepToCompletion() catch db.fatal(src);
                },
            }
        }

        fn ColType(col: std.meta.FieldEnum(config.cols)) type {
            const c: config.cols = undefined;
            return @TypeOf(@field(c, @tagName(col)));
        }

        fn bind(stmt: zqlite.Stmt, db: Database, args: config.args) void {
            stmt.reset() catch db.fatal(@src());
            inline for (@typeInfo(config.args).@"struct".fields, 0..) |f, idx| {
                stmt.bindValue(@field(args, f.name), idx) catch db.fatal(@src());
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

        pub const Row = struct {
            row: zqlite.Row,

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

            fn coerce(r: Row, T: type, idx: usize) T {
                switch (T) {
                    f64 => return r.row.float(idx),
                    u32, u64, i64 => return @intCast(r.row.int(idx)),
                    ?u64 => {
                        const value = r.row.nullableInt(idx) orelse return null;
                        return @intCast(value);
                    },
                    []u8, []const u8 => @compileError("use textNoDupe()"),
                    bool => return r.row.boolean(idx),
                    ?bool => return r.row.nullableBoolean(idx),
                    else => switch (@typeInfo(T)) {
                        .@"enum" => {
                            return @enumFromInt(r.row.int(idx));
                        },
                        else => @compileError("type " ++ @typeName(T) ++ " not supported"),
                    },
                }
            }

            fn ColType(col: std.meta.FieldEnum(config.cols)) type {
                const c: config.cols = undefined;
                return @TypeOf(@field(c, @tagName(col)));
            }
        };
    };
}
