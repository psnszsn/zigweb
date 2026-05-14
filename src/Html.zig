const Html = @This();
const std = @import("std");
const Writer = std.Io.Writer;
const generated_attrs = @import("generated_attrs.zig");

writer: *Writer,

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
}

fn writeAttrs(w: *Writer, attrs: anytype) !void {
    inline for (@typeInfo(@TypeOf(attrs)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "hx")) {
            try writeHxAttrs(w, @field(attrs, f.name));
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
