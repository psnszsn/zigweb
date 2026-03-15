const Html = @This();
const std = @import("std");
const Writer = std.Io.Writer;
const superhtml_html = @import("superhtml").html;

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

    const FieldAttrs = std.builtin.Type.StructField.Attributes;
    const null_str: ?[]const u8 = null;
    const null_bool: ?bool = null;
    const default_str = FieldAttrs{ .default_value_ptr = @ptrCast(&null_str) };
    const default_bool = FieldAttrs{ .default_value_ptr = @ptrCast(&null_bool) };

    pub fn Attrs(comptime tag: Tag) type {
        @setEvalBranchQuota(10000);
        const htmx_names: []const []const u8 = &.{
            "hx-get",      "hx-post",     "hx-put",      "hx-delete",   "hx-patch",
            "hx-trigger",  "hx-target",   "hx-swap",     "hx-include",  "hx-select",
            "hx-confirm",  "hx-push-url", "hx-vals",     "hx-sync",     "hx-boost",
        };

        const kind = std.meta.stringToEnum(superhtml_html.Ast.Kind, tag.str()) orelse
            return @Struct(.auto, null, &.{}, &.{}, &.{});

        const elem_set = superhtml_html.Attribute.element_attrs.get(kind);
        const global_set = &superhtml_html.Attribute.global;

        const max_fields = elem_set.list.len + global_set.list.len + htmx_names.len;
        var names: [max_fields][]const u8 = undefined;
        var types: [max_fields]type = undefined;
        var attrs: [max_fields]FieldAttrs = undefined;
        var count: usize = 0;

        for ([_][]const superhtml_html.Attribute.Named{ elem_set.list, global_set.list }) |list| {
            for (list) |named| {
                const is_bool = switch (named.model.rule) {
                    .bool => true,
                    else => false,
                };
                names[count] = named.name;
                types[count] = if (is_bool) ?bool else ?[]const u8;
                attrs[count] = if (is_bool) default_bool else default_str;
                count += 1;
            }
        }

        for (htmx_names) |hx_name| {
            names[count] = hx_name;
            types[count] = ?[]const u8;
            attrs[count] = default_str;
            count += 1;
        }

        return @Struct(.auto, null, names[0..count], types[0..count], attrs[0..count]);
    }
};

// -- Element API --

pub fn open(h: *Html, comptime tag: Tag, attrs: tag.Attrs()) !void {
    try h.writer.print("<{s}", .{tag.str()});
    try writeAttrs(h.writer, attrs);
    if (tag.isVoid()) {
        try h.writer.writeAll(" />");
    } else {
        try h.writer.writeAll(">");
    }
}

fn writeAttrs(w: *Writer, attrs: anytype) !void {
    inline for (@typeInfo(@TypeOf(attrs)).@"struct".fields) |f| {
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
