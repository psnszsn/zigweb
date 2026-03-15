const zigweb = @import("zigweb");
const std = @import("std");
const Io = std.Io;
const App = @import("../main.zig").App;

pub const Html = struct {
    inner: *zigweb.Html,
    app: *const App,
    io: Io,
    session: ?i64,

    pub fn open(h: Html, tag: zigweb.Html.Tag, attrs: []const zigweb.Html.Attr) !void {
        try h.inner.open(tag, attrs);
    }

    pub fn close(h: Html, tag: zigweb.Html.Tag) void {
        h.inner.close(tag);
    }

    pub fn text(h: Html, s: []const u8) !void {
        try h.inner.text(s);
    }

    pub fn raw(h: Html, s: []const u8) !void {
        try h.inner.raw(s);
    }
};

pub fn renderPage(inner: *zigweb.Html, comptime page: fn (Html) anyerror!void, session: ?i64, io: Io, app: *const App) !void {
    const h: Html = .{ .inner = inner, .app = app, .io = io, .session = session };

    try h.raw("<!DOCTYPE html>");
    try h.open(.html, &.{.{ .lang = "en" }});
    defer h.close(.html);

    {
        try h.open(.head, &.{});
        defer h.close(.head);

        try h.open(.meta, &.{.{ .charset = "utf-8" }});
        try h.open(.meta, &.{ .{ .name = "viewport" }, .{ .content = "width=device-width, initial-scale=1" } });

        {
            try h.open(.title, &.{});
            defer h.close(.title);
            try h.text("ZigWeb Demo");
        }

        try h.open(.link, &.{ .{ .rel = "stylesheet" }, .{ .href = "/style.css" } });
    }

    {
        try h.open(.body, &.{});
        defer h.close(.body);

        if (h.session != null) {
            try h.open(.nav, &.{});
            defer h.close(.nav);

            {
                try h.open(.a, &.{.{ .href = "/" }});
                defer h.close(.a);
                try h.text("Home");
            }
            {
                try h.open(.a, &.{.{ .href = "/notes" }});
                defer h.close(.a);
                try h.text("Notes");
            }
        }

        {
            try h.open(.main, &.{});
            defer h.close(.main);
            try page(h);
        }

        {
            try h.open(.script, &.{.{ .src = "/auth.js" }});
            h.close(.script);
        }
    }
}
