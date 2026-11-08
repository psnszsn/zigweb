//! Debug-build checks for the two ways a connection ends up writing on a
//! stale read snapshot, which SQLite answers with an *instant*
//! `SQLITE_BUSY_SNAPSHOT` that `busy_timeout` never retries:
//!
//! - a read cursor left open (not drained, not reset) when a write starts
//!   outside an explicit transaction, or when `BEGIN IMMEDIATE` runs;
//! - a deferred `BEGIN` whose first statement read, followed by a write.
//!
//! Both leave the connection holding a *read* transaction
//! (`sqlite3_txn_state == SQLITE_TXN_READ`) at the moment a write starts.
//! In production that only fails when another connection commits inside
//! the window, so it shows as a rare race; here it panics on every run of
//! the code path, naming the write and the cursors still open.
//!
//! `install` hooks `sqlite3_trace_v2(SQLITE_TRACE_STMT)`, so every statement
//! is seen, raw zqlite calls included. It replaces any trace callback the
//! connection had. Outside Debug builds both functions compile to nothing.
const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const c = zqlite.c;

const log = std.log.scoped(.db_debug);

const enabled = builtin.mode == .debug;

/// Panic whenever a write starts on a read snapshot. Call once per
/// connection, right after opening it.
pub fn install(conn: zqlite.Conn) void {
    if (!enabled) return;
    installWith(conn, null);
}

/// Panic when a connection goes back to a pool still inside a transaction
/// or with a cursor open: the next user of the connection would inherit it.
pub fn assertIdle(conn: zqlite.Conn) void {
    if (!enabled) return;
    switch (idleViolation(conn.conn) orelse return) {
        .transaction_open => std.debug.panic("connection released inside a transaction (missing commit or rollback)", .{}),
        .cursor_open => |stmt| std.debug.panic("connection released with a cursor open: {s}", .{sqlText(stmt)}),
    }
}

const Cause = enum {
    /// Outside an explicit transaction: the snapshot is held by a cursor.
    open_cursor,
    /// Inside an explicit transaction that read before writing.
    deferred_begin,
};

/// Tests pass one to see the hazards instead of panicking.
const Recorder = struct {
    count: usize = 0,
    last: ?Cause = null,
};

fn installWith(conn: zqlite.Conn, recorder: ?*Recorder) void {
    const rc = c.sqlite3_trace_v2(conn.conn, c.SQLITE_TRACE_STMT, &onStatement, recorder);
    if (rc != c.SQLITE_OK) std.debug.panic("sqlite3_trace_v2 failed: {d}", .{rc});
}

fn onStatement(_: c_uint, ctx: ?*anyopaque, p: ?*anyopaque, x: ?*anyopaque) callconv(.c) c_int {
    const stmt: *c.sqlite3_stmt = @ptrCast(p orelse return 0);
    // X is the statement's own SQL when it starts; a trigger subprogram (or
    // a statement run from inside another) gets a separate "-- ..." string.
    // The statement that fired those was already checked.
    if (x != @as(?*const anyopaque, c.sqlite3_sql(stmt))) return 0;

    const cause = writeHazard(stmt) orelse return 0;
    if (ctx) |r| {
        const recorder: *Recorder = @ptrCast(@alignCast(r));
        recorder.count += 1;
        recorder.last = cause;
        return 0;
    }

    const db = c.sqlite3_db_handle(stmt).?;
    var open: ?*c.sqlite3_stmt = null;
    while (nextBusy(db, open)) |other| : (open = other) {
        if (other != stmt) log.err("cursor still open: {s}", .{sqlText(other)});
    }
    switch (cause) {
        .open_cursor => std.debug.panic(
            "write started while a read cursor holds a snapshot (SQLITE_BUSY_SNAPSHOT under concurrency); " ++
                "drain or deinit the cursor first. Write: {s}",
            .{sqlText(stmt)},
        ),
        .deferred_begin => std.debug.panic(
            "write started in a transaction that read first (SQLITE_BUSY_SNAPSHOT under concurrency); " ++
                "open it with BEGIN IMMEDIATE. Write: {s}",
            .{sqlText(stmt)},
        ),
    }
}

/// Whether `stmt`, about to start, writes on a read snapshot.
fn writeHazard(stmt: *c.sqlite3_stmt) ?Cause {
    const db = c.sqlite3_db_handle(stmt).?;
    if (c.sqlite3_txn_state(db, "main") != c.SQLITE_TXN_READ) return null;
    // False for BEGIN IMMEDIATE/EXCLUSIVE too: they take the write lock.
    if (c.sqlite3_stmt_readonly(stmt) != 0) return null;
    return if (c.sqlite3_get_autocommit(db) != 0) .open_cursor else .deferred_begin;
}

const IdleViolation = union(enum) {
    transaction_open,
    cursor_open: *c.sqlite3_stmt,
};

fn idleViolation(db: *c.sqlite3) ?IdleViolation {
    if (c.sqlite3_get_autocommit(db) == 0) return .transaction_open;
    if (nextBusy(db, null)) |stmt| return .{ .cursor_open = stmt };
    return null;
}

/// The next prepared statement after `after` that has started and is
/// neither drained nor reset.
fn nextBusy(db: *c.sqlite3, after: ?*c.sqlite3_stmt) ?*c.sqlite3_stmt {
    var it = c.sqlite3_next_stmt(db, after);
    while (it) |stmt| : (it = c.sqlite3_next_stmt(db, stmt)) {
        if (c.sqlite3_stmt_busy(stmt) != 0) return stmt;
    }
    return null;
}

fn sqlText(stmt: *c.sqlite3_stmt) []const u8 {
    const sql = c.sqlite3_sql(stmt) orelse return "?";
    return std.mem.span(sql);
}

const t = std.testing;

fn testConn(recorder: *Recorder) !zqlite.Conn {
    const conn = try zqlite.open(":memory:", zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
    try conn.execNoArgs(
        \\CREATE TABLE a (id INTEGER PRIMARY KEY, v INTEGER NOT NULL);
        \\CREATE TABLE log (id INTEGER PRIMARY KEY, a_id INTEGER NOT NULL);
        \\CREATE TRIGGER a_logged AFTER UPDATE ON a BEGIN INSERT INTO log (a_id) VALUES (new.id); END;
        \\INSERT INTO a (v) VALUES (1), (2), (3);
    );
    installWith(conn, recorder);
    return conn;
}

test "a write over an open cursor is a hazard" {
    var recorder: Recorder = .{};
    const conn = try testConn(&recorder);
    defer conn.close();

    const row = (try conn.row("SELECT id FROM a WHERE v = 1", .{})).?;
    try conn.exec("UPDATE a SET v = 10 WHERE id = ?", .{row.int(0)});
    // SQL that starts with a comment is still the statement's own text.
    try conn.exec("-- why\nUPDATE a SET v = 11 WHERE id = ?", .{row.int(0)});
    row.deinit();

    try t.expectEqual(2, recorder.count);
    try t.expectEqual(Cause.open_cursor, recorder.last.?);
}

test "BEGIN IMMEDIATE over an open cursor is a hazard" {
    var recorder: Recorder = .{};
    const conn = try testConn(&recorder);
    defer conn.close();

    const row = (try conn.row("SELECT id FROM a WHERE v = 1", .{})).?;
    try conn.execNoArgs("BEGIN IMMEDIATE");
    row.deinit();
    conn.rollback();

    try t.expectEqual(1, recorder.count);
    try t.expectEqual(Cause.open_cursor, recorder.last.?);
}

test "a deferred BEGIN that reads before it writes is a hazard" {
    var recorder: Recorder = .{};
    const conn = try testConn(&recorder);
    defer conn.close();

    try conn.transaction();
    const row = (try conn.row("SELECT id FROM a WHERE v = 1", .{})).?;
    const id = row.int(0);
    row.deinit();
    try conn.exec("UPDATE a SET v = 10 WHERE id = ?", .{id});
    try conn.commit();

    try t.expectEqual(1, recorder.count);
    try t.expectEqual(Cause.deferred_begin, recorder.last.?);
}

test "safe shapes are not hazards" {
    var recorder: Recorder = .{};
    const conn = try testConn(&recorder);
    defer conn.close();

    // A reset cursor, then a write (the trigger's insert is not re-checked).
    {
        const row = (try conn.row("SELECT id FROM a WHERE v = 1", .{})).?;
        const id = row.int(0);
        row.deinit();
        try conn.exec("UPDATE a SET v = 10 WHERE id = ?", .{id});
    }
    // A drained cursor, then a write.
    {
        var rows = try conn.rows("SELECT id FROM a", .{});
        while (rows.next()) |_| {}
        try conn.exec("UPDATE a SET v = v + 1", .{});
        rows.deinit();
    }
    // BEGIN IMMEDIATE, a cursor left open across writes.
    {
        try conn.execNoArgs("BEGIN IMMEDIATE");
        var rows = try conn.rows("SELECT id FROM a", .{});
        while (rows.next()) |r| try conn.exec("UPDATE a SET v = v + 1 WHERE id = ?", .{r.int(0)});
        rows.deinit();
        try conn.commit();
    }
    // A deferred BEGIN whose first statement writes.
    {
        try conn.transaction();
        try conn.exec("UPDATE a SET v = 0 WHERE id = 1", .{});
        const row = (try conn.row("SELECT v FROM a WHERE id = 1", .{})).?;
        row.deinit();
        try conn.exec("UPDATE a SET v = 1 WHERE id = 1", .{});
        try conn.commit();
    }
    // An open cursor while only reading.
    {
        const row = (try conn.row("SELECT id FROM a WHERE v = 1", .{})) orelse unreachable;
        const other = try conn.row("SELECT count(*) FROM a", .{});
        other.?.deinit();
        row.deinit();
    }

    try t.expectEqual(0, recorder.count);
}

test "idleViolation sees an open transaction and an open cursor" {
    var recorder: Recorder = .{};
    const conn = try testConn(&recorder);
    defer conn.close();

    try t.expectEqual(null, idleViolation(conn.conn));

    try conn.execNoArgs("BEGIN IMMEDIATE");
    try t.expectEqual(IdleViolation.transaction_open, idleViolation(conn.conn).?);
    conn.rollback();

    const row = (try conn.row("SELECT id FROM a", .{})).?;
    try t.expect(idleViolation(conn.conn).? == .cursor_open);
    row.deinit();

    var rows = try conn.rows("SELECT id FROM a", .{});
    while (rows.next()) |_| {}
    try t.expectEqual(null, idleViolation(conn.conn));
    rows.deinit();
}

test "install and assertIdle pass on safe use" {
    var unused: Recorder = .{};
    const conn = try testConn(&unused);
    defer conn.close();
    install(conn); // the panicking hook replaces the recorder

    const row = (try conn.row("SELECT id FROM a WHERE v = 1", .{})).?;
    const id = row.int(0);
    row.deinit();
    try conn.exec("UPDATE a SET v = 10 WHERE id = ?", .{id});
    try conn.execNoArgs("BEGIN IMMEDIATE");
    try conn.exec("UPDATE a SET v = 11 WHERE id = ?", .{id});
    try conn.commit();
    assertIdle(conn);
}
