//! URL query-string parsing helpers.

const std = @import("std");

/// Streams `application/x-www-form-urlencoded` pairs from a reader.
/// The `*Pair` returned by `next()` aliases iterator-owned storage —
/// consume it (via `eql_key`, `value_reader`) before the next call.
pub const FormIterator = struct {
    upstream: *std.Io.Reader,
    current: Pair = .{},

    pub const Pair = struct {
        raw_key: []const u8 = "",
        raw_value: []const u8 = "",
        read_pos: usize = 0,
        /// `std.Io.Reader` over the decoded bytes of `raw_value`.
        value_reader: std.Io.Reader = .{
            .buffer = &.{},
            .vtable = &value_reader_vtable,
            .seek = 0,
            .end = 0,
        },

        const value_reader_vtable: std.Io.Reader.VTable = .{ .stream = readValue };

        /// `raw_key`, after `+`/`%XX` decoding, equals `needle`.
        /// Decodes on the fly — no allocation.
        pub fn eql_key(p: *const Pair, needle: []const u8) bool {
            return eqlDecoded(p.raw_key, needle);
        }

        fn readValue(
            r: *std.Io.Reader,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            const p: *Pair = @alignCast(@fieldParentPtr("value_reader", r));
            const tail = p.raw_value[p.read_pos..];
            if (tail.len == 0) return error.EndOfStream;

            const idx = std.mem.indexOfAny(u8, tail, "+%") orelse tail.len;
            if (idx > 0) {
                const n = @min(idx, @intFromEnum(limit));
                try w.writeAll(tail[0..n]);
                p.read_pos += n;
                return n;
            }

            if (@intFromEnum(limit) == 0) return 0;
            const decoded: u8, const consumed: usize = decodeByte(tail);
            try w.writeByte(decoded);
            p.read_pos += consumed;
            return 1;
        }
    };

    pub const Error = std.Io.Reader.Error || error{StreamTooLong};

    pub fn init(upstream: *std.Io.Reader) FormIterator {
        return .{ .upstream = upstream };
    }

    pub fn next(self: *FormIterator) Error!?*Pair {
        while (try self.upstream.takeDelimiter('&')) |pair| {
            if (pair.len == 0) continue;
            const k, const v = std.mem.cutScalar(u8, pair, '=') orelse .{ pair, "" };
            self.current = .{ .raw_key = k, .raw_value = v };
            return &self.current;
        }
        return null;
    }
};

/// No-special fast path collapses to a single `std.mem.eql`.
fn eqlDecoded(raw: []const u8, needle: []const u8) bool {
    var r = raw;
    var n = needle;
    while (std.mem.indexOfAny(u8, r, "+%")) |idx| {
        if (n.len <= idx) return false;
        if (!std.mem.eql(u8, r[0..idx], n[0..idx])) return false;
        const decoded: u8, const consumed: usize = decodeByte(r[idx..]);
        if (n[idx] != decoded) return false;
        r = r[idx + consumed ..];
        n = n[idx + 1 ..];
    }
    return std.mem.eql(u8, r, n);
}

/// Returns the decoded byte and how many input bytes it consumed
/// (1 or 3). Malformed `%X` passes through as literal `%`.
fn decodeByte(raw: []const u8) struct { u8, usize } {
    switch (raw[0]) {
        '+' => return .{ ' ', 1 },
        '%' => {
            if (raw.len >= 3) {
                if (std.fmt.parseInt(u8, raw[1..3], 16)) |b| return .{ b, 3 } else |_| {}
            }
            return .{ '%', 1 };
        },
        else => |c| return .{ c, 1 },
    }
}

pub fn parseQueryInto(comptime T: type, raw: []const u8, buf: []u8) T {
    const s = @typeInfo(T).@"struct";
    var result: T = .{};
    var seen: [s.field_names.len]bool = @splat(false);
    var cursor: usize = 0;

    var reader = std.Io.Reader.fixed(raw);
    var it = FormIterator.init(&reader);
    // `next` can only error here on a pair larger than `raw` — impossible.
    while (it.next() catch null) |pair| {
        inline for (s.field_names, s.field_types, 0..) |name, FieldType, i| {
            if (!seen[i] and pair.eql_key(name)) {
                seen[i] = true;
                switch (@typeInfo(FieldType)) {
                    .optional => |o| {
                        const Child = o.child;
                        const child_info = @typeInfo(Child);
                        if (child_info == .pointer and child_info.pointer.child == u8) {
                            if (pair.raw_value.len == 0) {
                                @field(result, name) = null;
                            } else {
                                var w = std.Io.Writer.fixed(buf[cursor..]);
                                _ = pair.value_reader.streamRemaining(&w) catch break;
                                @field(result, name) = w.buffered();
                                cursor += w.end;
                            }
                        } else if (Child == bool) {
                            // raw_value is fine — "true"/"false"/"0"/"1" never contain '+'/'%'.
                            if (std.mem.eql(u8, pair.raw_value, "true") or std.mem.eql(u8, pair.raw_value, "1")) {
                                @field(result, name) = true;
                            } else if (std.mem.eql(u8, pair.raw_value, "false") or std.mem.eql(u8, pair.raw_value, "0")) {
                                @field(result, name) = false;
                            }
                        } else {
                            @compileError("parseQueryInto: unsupported optional field type " ++ @typeName(Child));
                        }
                    },
                    .int => {
                        if (std.fmt.parseInt(FieldType, pair.raw_value, 10)) |n| {
                            @field(result, name) = n;
                        } else |_| {}
                    },
                    else => @compileError("parseQueryInto: unsupported field type " ++ @typeName(FieldType) ++ " for field '" ++ name ++ "'"),
                }
                break;
            }
        }
    }
    return result;
}

test "FormIterator: walks raw pairs" {
    var reader = std.Io.Reader.fixed("name=alice&note=hello+world&tag=x");
    var it = FormIterator.init(&reader);

    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("name", a.raw_key);
    try std.testing.expectEqualStrings("alice", a.raw_value);

    const b = (try it.next()).?;
    try std.testing.expectEqualStrings("note", b.raw_key);
    try std.testing.expectEqualStrings("hello+world", b.raw_value);

    const c = (try it.next()).?;
    try std.testing.expectEqualStrings("tag", c.raw_key);
    try std.testing.expectEqualStrings("x", c.raw_value);

    try std.testing.expect((try it.next()) == null);
}

test "FormIterator: empty pairs skipped, missing value → empty raw_value" {
    var reader = std.Io.Reader.fixed("&&a=1&&flag&b=2&");
    var it = FormIterator.init(&reader);
    const p1 = (try it.next()).?;
    try std.testing.expectEqualStrings("a", p1.raw_key);
    try std.testing.expectEqualStrings("1", p1.raw_value);
    const p2 = (try it.next()).?;
    try std.testing.expectEqualStrings("flag", p2.raw_key);
    try std.testing.expectEqualStrings("", p2.raw_value);
    const p3 = (try it.next()).?;
    try std.testing.expectEqualStrings("b", p3.raw_key);
    try std.testing.expectEqualStrings("2", p3.raw_value);
    try std.testing.expect((try it.next()) == null);
}

test "Pair.eql_key: plain, plus, percent" {
    const plain: FormIterator.Pair = .{ .raw_key = "user_name", .raw_value = "" };
    try std.testing.expect(plain.eql_key("user_name"));
    try std.testing.expect(!plain.eql_key("user"));
    try std.testing.expect(!plain.eql_key("user_names"));

    const plus: FormIterator.Pair = .{ .raw_key = "hello+world", .raw_value = "" };
    try std.testing.expect(plus.eql_key("hello world"));
    try std.testing.expect(!plus.eql_key("hello+world"));

    const pct: FormIterator.Pair = .{ .raw_key = "a%2Cb", .raw_value = "" };
    try std.testing.expect(pct.eql_key("a,b"));
    try std.testing.expect(!pct.eql_key("a%2Cb"));
}

test "Pair.value_reader: plain, plus, percent, mixed" {
    var out: [64]u8 = undefined;

    var p1: FormIterator.Pair = .{ .raw_key = "k", .raw_value = "plain" };
    var w1 = std.Io.Writer.fixed(&out);
    _ = try p1.value_reader.streamRemaining(&w1);
    try std.testing.expectEqualStrings("plain", w1.buffered());

    var p2: FormIterator.Pair = .{ .raw_key = "k", .raw_value = "hello+world%21" };
    var w2 = std.Io.Writer.fixed(&out);
    _ = try p2.value_reader.streamRemaining(&w2);
    try std.testing.expectEqualStrings("hello world!", w2.buffered());

    var p3: FormIterator.Pair = .{ .raw_key = "k", .raw_value = "" };
    var w3 = std.Io.Writer.fixed(&out);
    _ = try p3.value_reader.streamRemaining(&w3);
    try std.testing.expectEqualStrings("", w3.buffered());
}

test "parseQueryInto: optional strings and ints" {
    const TestFilters = struct {
        type: ?[]const u8 = null,
        state: ?[]const u8 = null,
        page: usize = 1,
        size: usize = 50,
    };
    var buf: [128]u8 = undefined;
    const f = parseQueryInto(TestFilters, "type=card_payment&state=completed&page=3&size=25", &buf);
    try std.testing.expectEqualStrings("card_payment", f.type.?);
    try std.testing.expectEqualStrings("completed", f.state.?);
    try std.testing.expectEqual(@as(usize, 3), f.page);
    try std.testing.expectEqual(@as(usize, 25), f.size);
}

test "parseQueryInto: optional bool true/false and 1/0" {
    const F = struct { a: ?bool = null, b: ?bool = null, c: ?bool = null, d: ?bool = null };
    var buf: [32]u8 = undefined;
    const f = parseQueryInto(F, "a=true&b=false&c=1&d=0", &buf);
    try std.testing.expectEqual(@as(?bool, true), f.a);
    try std.testing.expectEqual(@as(?bool, false), f.b);
    try std.testing.expectEqual(@as(?bool, true), f.c);
    try std.testing.expectEqual(@as(?bool, false), f.d);
}
