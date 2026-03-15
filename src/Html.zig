const Html = @This();
const std = @import("std");
const Writer = std.Io.Writer;

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

    pub fn str(self: Tag) []const u8 {
        return @tagName(self);
    }

    pub fn isVoid(self: Tag) bool {
        return switch (self) {
            .input, .br, .hr, .meta, .link, .img => true,
            else => false,
        };
    }
};

// -- Attr union --

pub const Attr = union(enum) {
    class: []const u8,
    id: []const u8,
    href: []const u8,
    method: []const u8,
    action: []const u8,
    @"type": []const u8,
    name: []const u8,
    value: []const u8,
    rel: []const u8,
    charset: []const u8,
    content: []const u8,
    src: []const u8,
    alt: []const u8,
    @"for": []const u8,
    placeholder: []const u8,
    rows: []const u8,
    datetime: []const u8,
    @"hx-get": []const u8,
    @"hx-post": []const u8,
    @"hx-delete": []const u8,
    @"hx-target": []const u8,
    @"hx-swap": []const u8,
    @"hx-trigger": []const u8,
    @"hx-vals": []const u8,
    @"hx-confirm": []const u8,
    @"hx-include": []const u8,
    @"hx-sync": []const u8,
    @"hx-push-url": []const u8,
    inputmode: []const u8,
    enterkeyhint: []const u8,
    step: []const u8,
    lang: []const u8,
    enctype: []const u8,
    accept: []const u8,
    loading: []const u8,
    referrerpolicy: []const u8,
    disabled: bool,
    download: bool,
    selected: bool,
    required: bool,
    checked: bool,

    pub fn write(self: Attr, w: *Writer) !void {
        switch (self) {
            .disabled, .download, .selected, .required, .checked => |val| {
                if (val) try w.print(" {s}", .{@tagName(self)});
            },
            inline else => |val, tag| {
                try w.print(" {s}=\"", .{@tagName(tag)});
                try escapeAttr(w, val);
                try w.writeAll("\"");
            },
        }
    }
};

// -- Element API --

pub fn open(h: *Html, tag: Tag, attrs: []const Attr) !void {
    try h.writer.print("<{s}", .{tag.str()});
    for (attrs) |attr| {
        try attr.write(h.writer);
    }
    if (tag.isVoid()) {
        try h.writer.writeAll(" />");
    } else {
        try h.writer.writeAll(">");
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
