const Html = @This();
const std = @import("std");
const Writer = std.Io.Writer;
const generated_attrs = @import("generated_attrs.zig");

writer: *Writer,
scratch: [4096]u8 = undefined,
scratch_used: usize = 0,

// -- Tag enum --

pub const Tag = enum {
    html,
    head,
    title,
    meta,
    link,
    body,
    div,
    span,
    p,
    a,
    button,
    input,
    br,
    hr,
    ul,
    ol,
    li,
    h1,
    h2,
    h3,
    section,
    nav,
    header,
    footer,
    main,
    form,
    label,
    table,
    tr,
    td,
    th,
    thead,
    tbody,
    script,
    img,
    textarea,
    select,
    option,
    time,
    article,
    small,
    details,
    summary,

    pub fn str(self: Tag) []const u8 {
        return @tagName(self);
    }

    pub fn isVoid(self: Tag) bool {
        return switch (self) {
            .input, .br, .hr, .meta, .link, .img => true,
            else => false,
        };
    }

    pub fn Attrs(comptime tag: Tag) type {
        return @field(generated_attrs, @tagName(tag));
    }
};

// -- Element API --

pub fn open(h: *Html, comptime tag: Tag, attrs: tag.Attrs()) !void {
    try h.writer.print("<{s}", .{tag.str()});
    try writeAttrs(h.writer, attrs);
    try h.writer.writeAll(">");
    h.scratch_used = 0;
}

/// Format into an internal scratch buffer and return a slice into
/// it. The slice stays valid until the next `h.open(...)` call,
/// which resets the buffer. Intended for computing strings to pass
/// as `h.open` attribute values.
pub fn fmt(h: *Html, comptime f: []const u8, args: anytype) ![]const u8 {
    const s = try std.fmt.bufPrint(h.scratch[h.scratch_used..], f, args);
    h.scratch_used += s.len;
    return s;
}

fn writeAttrs(w: *Writer, attrs: anytype) !void {
    inline for (@typeInfo(@TypeOf(attrs)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "hx")) {
            try writeHxAttrs(w, @field(attrs, f.name));
            continue;
        }
        if (comptime std.mem.eql(u8, f.name, "aria")) {
            try writeAriaAttrs(w, @field(attrs, f.name));
            continue;
        }
        if (@field(attrs, f.name)) |val| {
            if (@TypeOf(val) == bool) {
                if (val) try w.print(" {s}", .{f.name});
            } else {
                try w.print(" {s}=\"", .{f.name});
                try escapeAttr(w, val);
                try w.writeAll("\"");
            }
        }
    }
}

fn writeHxAttrs(w: *Writer, hx: generated_attrs.Hx) !void {
    inline for (@typeInfo(generated_attrs.Hx).@"struct".fields) |f| {
        if (@field(hx, f.name)) |val| {
            const wire = comptime blk: {
                var arr: [3 + f.name.len]u8 = ("hx-" ++ f.name).*;
                std.mem.replaceScalar(u8, &arr, '_', '-');
                break :blk arr;
            };
            try w.print(" {s}=\"", .{&wire});
            try escapeAttr(w, val);
            try w.writeAll("\"");
        }
    }
}

fn writeAriaAttrs(w: *Writer, aria: generated_attrs.Aria) !void {
    inline for (@typeInfo(generated_attrs.Aria).@"struct".fields) |f| {
        if (@field(aria, f.name)) |val| {
            const wire = comptime blk: {
                var arr: [5 + f.name.len]u8 = ("aria-" ++ f.name).*;
                std.mem.replaceScalar(u8, &arr, '_', '-');
                break :blk arr;
            };
            try w.print(" {s}=\"", .{&wire});
            try escapeAttr(w, val);
            try w.writeAll("\"");
        }
    }
}

pub fn close(h: *Html, tag: Tag) void {
    if (tag.isVoid()) return;
    h.writer.print("</{s}>", .{tag.str()}) catch |err| {
        std.log.err("Html.close({s}): {}", .{ tag.str(), err });
    };
}

pub fn text(h: *Html, s: []const u8) !void {
    try escapeText(h.writer, s);
}

pub fn raw(h: *Html, s: []const u8) !void {
    try h.writer.writeAll(s);
}

/// Format with HTML escaping (no intermediate buffer).
pub fn print(h: *Html, comptime f: []const u8, args: anytype) !void {
    var esc: EscapingWriter = .{ .out = h.writer };
    try esc.writer.print(f, args);
}

const EscapingWriter = struct {
    out: *Writer,
    writer: Writer = .{
        .buffer = &.{},
        .vtable = &.{ .drain = drain },
    },

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *EscapingWriter = @alignCast(@fieldParentPtr("writer", w));
        for (data[0 .. data.len - 1]) |chunk| try escapeText(self.out, chunk);
        for (0..splat) |_| try escapeText(self.out, data[data.len - 1]);
        return Writer.countSplat(data, splat);
    }
};

// -- Escaping --

fn escapeText(w: *Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            else => try w.writeByte(c),
        }
    }
}

test "print escapes formatted values" {
    var buf: [128]u8 = undefined;
    var out = Writer.fixed(&buf);
    var h: Html = .{ .writer = &out };
    try h.print("name={s} count={d}", .{ "<a&b>", 42 });
    try std.testing.expectEqualStrings("name=&lt;a&amp;b&gt; count=42", out.buffered());
}

fn escapeAttr(w: *Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("&quot;"),
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        }
    }
}
