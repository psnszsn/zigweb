const std = @import("std");
const zigweb = @import("zigweb");

const t = std.testing;
const Database = zigweb.Database;
const zqlite = zigweb.zqlite;

const Flavor = enum(i64) {
    vanilla = 1,
    chocolate = 2,
};

const PackedFlags = packed struct(u8) {
    admin: bool,
    editor: bool,
    _: u6 = 0,
};

const BindingQueries = struct {
    insert_positional: Database.Query(
        "INSERT INTO binding_test (id, flavor, maybe_flavor, flags, lo, hi, score) VALUES (?, ?, ?, ?, ?, ?, ?)",
        .{
            .kind = .exec,
            .args = struct {
                i64,
                Flavor,
                ?Flavor,
                PackedFlags,
                i64,
                i64,
                f64,
            },
        },
    ),
    insert_named: Database.Query(
        "INSERT INTO binding_test (id, flavor, maybe_flavor, flags, lo, hi, score) VALUES (:id, :flavor, :maybe_flavor, :flags, :bound, :bound, :score)",
        .{
            .kind = .exec,
            .args = struct {
                id: i64,
                flavor: Flavor,
                maybe_flavor: ?Flavor,
                flags: PackedFlags,
                bound: i64,
                score: f64,
            },
        },
    ),
    select_row: Database.Query(
        "SELECT flavor, maybe_flavor, flags, lo, hi, score FROM binding_test WHERE id = ?",
        .{
            .kind = .row,
            .cols = struct {
                flavor: Flavor,
                maybe_flavor: ?Flavor,
                flags: i64,
                lo: ?i64,
                hi: ?u64,
                score: ?f64,
            },
            .args = struct { i64 },
        },
    ),
    select_named_row: Database.Query(
        "SELECT flavor, maybe_flavor, flags, lo, hi, score FROM binding_test WHERE id = :id",
        .{
            .kind = .row,
            .cols = struct {
                flavor: Flavor,
                maybe_flavor: ?Flavor,
                flags: i64,
                lo: ?i64,
                hi: ?u64,
                score: ?f64,
            },
            .args = struct { id: i64 },
        },
    ),
};

fn openTestDb() Database {
    const conn = zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode) catch
        @panic("failed to open in-memory db");
    conn.execNoArgs(
        \\CREATE TABLE binding_test (
        \\  id INTEGER PRIMARY KEY,
        \\  flavor INTEGER NOT NULL,
        \\  maybe_flavor INTEGER,
        \\  flags INTEGER NOT NULL,
        \\  lo INTEGER,
        \\  hi INTEGER,
        \\  score REAL
        \\)
    ) catch @panic("failed to create binding_test");
    return .{ .conn = conn };
}

test "Query positional binding handles enums optional enums and packed structs" {
    const db = openTestDb();
    defer db.close();

    var qs = db.initQueries(BindingQueries);
    defer db.deinitQueries(BindingQueries, &qs);

    try qs.insert_positional.run(@src(), db, .{
        1,
        .chocolate,
        .vanilla,
        .{ .admin = true, .editor = false },
        10,
        20,
        12.5,
    });

    const row = qs.select_row.run(@src(), db, .{1}).?;
    defer row.deinit();

    try t.expectEqual(Flavor.chocolate, row.get(.flavor));
    try t.expectEqual(@as(?Flavor, .vanilla), row.get(.maybe_flavor));
    try t.expectEqual(@as(i64, @intCast(@as(u8, @bitCast(@as(PackedFlags, .{ .admin = true, .editor = false }))))), row.get(.flags));
    try t.expectEqual(@as(?i64, 10), row.get(.lo));
    try t.expectEqual(@as(?u64, 20), row.get(.hi));
    try t.expectEqual(@as(?f64, 12.5), row.get(.score));
}

test "Query named :args bind by field and reuse repeated parameters" {
    const db = openTestDb();
    defer db.close();

    var qs = db.initQueries(BindingQueries);
    defer db.deinitQueries(BindingQueries, &qs);

    try qs.insert_named.run(@src(), db, .{
        .id = 2,
        .flavor = .vanilla,
        .maybe_flavor = null,
        .flags = .{ .admin = true, .editor = true },
        .bound = 77,
        .score = 3.25,
    });

    const row = qs.select_named_row.run(@src(), db, .{ .id = 2 }).?;
    defer row.deinit();

    try t.expectEqual(Flavor.vanilla, row.get(.flavor));
    try t.expectEqual(@as(?Flavor, null), row.get(.maybe_flavor));
    try t.expectEqual(@as(i64, @intCast(@as(u8, @bitCast(@as(PackedFlags, .{ .admin = true, .editor = true }))))), row.get(.flags));
    try t.expectEqual(@as(?i64, 77), row.get(.lo));
    try t.expectEqual(@as(?u64, 77), row.get(.hi));
    try t.expectEqual(@as(?f64, 3.25), row.get(.score));
}

fn countRows(db: Database) i64 {
    const row = (db.conn.row("SELECT count(*) FROM binding_test", .{}) catch unreachable).?;
    defer row.deinit();
    return row.int(0);
}

fn insertRow(qs: *const BindingQueries, db: Database, id: i64) !void {
    try qs.insert_positional.run(@src(), db, .{ id, .vanilla, null, .{ .admin = false, .editor = false }, 0, 0, 0 });
}

test "Tx commits, and rolls back when it ends uncommitted" {
    const db = openTestDb();
    defer db.close();
    var qs = db.initQueries(BindingQueries);
    defer db.deinitQueries(BindingQueries, &qs);

    {
        var tx = try db.begin();
        defer tx.end();
        try t.expect(!tx.nested);
        try insertRow(&qs, tx.db, 1);
        try tx.commit();
    }
    {
        var tx = try db.begin();
        defer tx.end();
        try insertRow(&qs, tx.db, 2);
    }
    try t.expectEqual(@as(i64, 1), countRows(db));
    try t.expect(zqlite.c.sqlite3_get_autocommit(db.conn.conn) != 0);
}

test "Tx rolls back on an early error return" {
    const db = openTestDb();
    defer db.close();
    var qs = db.initQueries(BindingQueries);
    defer db.deinitQueries(BindingQueries, &qs);

    const unit = struct {
        fn run(d: Database, q: *const BindingQueries) !void {
            var tx = try d.begin();
            defer tx.end();
            try insertRow(q, tx.db, 1);
            return error.Refused;
        }
    };
    try t.expectError(error.Refused, unit.run(db, &qs));
    try t.expectEqual(@as(i64, 0), countRows(db));
}

test "Tx savepoints commit and roll back inside the enclosing transaction" {
    const db = openTestDb();
    defer db.close();
    var qs = db.initQueries(BindingQueries);
    defer db.deinitQueries(BindingQueries, &qs);

    // Savepoint rolled back, outer committed: only the outer row stays.
    {
        var outer = try db.begin();
        defer outer.end();
        try insertRow(&qs, outer.db, 1);
        {
            var inner = try outer.savepoint();
            defer inner.end();
            try t.expect(inner.nested);
            try insertRow(&qs, inner.db, 2);
        }
        try outer.commit();
    }
    try t.expectEqual(@as(i64, 1), countRows(db));

    // Savepoint released, outer rolled back: nothing stays.
    {
        var outer = try db.begin();
        defer outer.end();
        var inner = try outer.savepoint();
        defer inner.end();
        try insertRow(&qs, inner.db, 3);
        try inner.commit();
    }
    try t.expectEqual(@as(i64, 1), countRows(db));
    try t.expect(zqlite.c.sqlite3_get_autocommit(db.conn.conn) != 0);
}
