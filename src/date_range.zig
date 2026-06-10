//! Shared date-range presets for date pickers. Used by the `Table`
//! `date_range` filter and by app pages that render their own picker
//! (e.g. report date ranges) so the preset boundaries stay identical.

const std = @import("std");
const zeit = @import("zeit");
const Html = @import("Html.zig");

pub const Preset = struct {
    label: []const u8,
    from: []const u8 = "",
    to: []const u8 = "",
};

/// Resolves the built-in presets relative to `now_inst` (interpreted as
/// UTC). Date strings are allocated via `allocator` — a stack-backed
/// FixedBufferAllocator at the call site is plenty (~90 bytes total) —
/// and must outlive the returned array. An empty string is an
/// open-ended bound; the "All" preset has both empty.
pub fn presets(allocator: std.mem.Allocator, now_inst: zeit.Instant) ![7]Preset {
    const fmtDate = struct {
        fn f(alloc: std.mem.Allocator, y: i32, m: u32, d: u32) ![]const u8 {
            return std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2}", .{ y, m, d });
        }
    }.f;

    const t = now_inst.time();
    const y = t.year;
    const mo: u32 = @intFromEnum(t.month);

    const lm_y: i32 = if (mo == 1) y - 1 else y;
    const lm_m: u32 = if (mo == 1) 12 else mo - 1;
    const lm_last: u32 = @as(zeit.Month, @enumFromInt(lm_m)).lastDay(lm_y);

    const today_days = zeit.daysFromCivil(.{ .year = y, .month = t.month, .day = t.day });
    const today_str = try fmtDate(allocator, y, mo, t.day);
    const d30 = zeit.civilFromDays(today_days - 30);
    const d90 = zeit.civilFromDays(today_days - 90);

    return .{
        .{ .label = "This month", .from = try fmtDate(allocator, y, mo, 1) },
        .{ .label = "Last month", .from = try fmtDate(allocator, lm_y, lm_m, 1), .to = try fmtDate(allocator, lm_y, lm_m, lm_last) },
        .{ .label = "This year", .from = try fmtDate(allocator, y, 1, 1) },
        .{ .label = "Last year", .from = try fmtDate(allocator, y - 1, 1, 1), .to = try fmtDate(allocator, y - 1, 12, 31) },
        .{ .label = "Last 30 days", .from = try fmtDate(allocator, d30.year, @intFromEnum(d30.month), d30.day), .to = today_str },
        .{ .label = "Last 90 days", .from = try fmtDate(allocator, d90.year, @intFromEnum(d90.month), d90.day), .to = today_str },
        .{ .label = "All" },
    };
}

pub const Dropdown = struct {
    /// Page the form submits to (also the preset links' path).
    base_path: []const u8,
    /// Currently selected bounds (drive the summary text + active pill).
    from: []const u8,
    to: []const u8,
    /// Current instant; presets are resolved against it and open-ended
    /// upper bounds ("This month") render through to today. `null`
    /// suppresses the presets row.
    now: ?zeit.Instant,
    from_name: []const u8 = "from",
    to_name: []const u8 = "to",
    from_label: []const u8 = "From",
    to_label: []const u8 = "To",
    apply_label: []const u8 = "Apply",
};

/// Renders the collapsed-pill date-range dropdown — the same shell as the
/// `Table` `date_range` filter (`filter-pill`/`filter-details`/`pill-body`)
/// — for plain pages that reload in full rather than hx-swapping a filter
/// region. The pills are plain links to `base_path?from=…&to=…`; the
/// Table's hx/filter-preserving variant lives in `Table.zig` and isn't
/// shared because it depends on the filter context. Both render from the
/// same `presets`.
pub fn renderDropdown(h: *Html, cfg: Dropdown) !void {
    var today_buf: [10]u8 = undefined;
    const today = blk: {
        const inst = cfg.now orelse break :blk "2099-12-31";
        var w: std.Io.Writer = .fixed(&today_buf);
        inst.time().strftime(&w, "%Y-%m-%d") catch break :blk "2099-12-31";
        break :blk today_buf[0..w.end];
    };

    try h.open(.div, .{ .class = "filter-pill is-selected" });
    defer h.close(.div);
    try h.open(.details, .{ .class = "filter-details" });
    defer h.close(.details);
    {
        try h.open(.summary, .{ .class = "pill-body" });
        defer h.close(.summary);
        try h.print("{s} – {s}", .{ cfg.from, cfg.to });
    }
    try h.open(.form, .{ .method = "get", .action = cfg.base_path, .class = "filter-form" });
    defer h.close(.form);

    if (cfg.now) |inst| {
        var fba_buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        if (presets(fba.allocator(), inst)) |ps| {
            try h.open(.div, .{ .style = "display: flex; flex-wrap: wrap; gap: 0.35rem;" });
            defer h.close(.div);
            for (ps) |p| {
                const pf = if (p.from.len > 0) p.from else "2000-01-01";
                const pt = if (p.to.len > 0) p.to else today;
                const active = std.mem.eql(u8, pf, cfg.from) and std.mem.eql(u8, pt, cfg.to);
                try h.open(.a, .{
                    .class = if (active) "btn btn-primary" else "btn",
                    .style = "padding: 4px 10px; font-size: 0.8rem;",
                    .href = try h.fmt("{s}?{s}={s}&{s}={s}", .{ cfg.base_path, cfg.from_name, pf, cfg.to_name, pt }),
                });
                defer h.close(.a);
                try h.text(p.label);
            }
        } else |_| {}
    }

    {
        try h.open(.div, .{ .style = "display: flex; gap: 0.5rem; align-items: end; flex-wrap: wrap; margin-top: 0.5rem;" });
        defer h.close(.div);
        {
            try h.open(.label, .{ .style = "display: flex; flex-direction: column; gap: 2px; font-size: 0.85em;" });
            defer h.close(.label);
            try h.text(cfg.from_label);
            try h.open(.input, .{ .type = "date", .name = cfg.from_name, .value = cfg.from });
        }
        {
            try h.open(.label, .{ .style = "display: flex; flex-direction: column; gap: 2px; font-size: 0.85em;" });
            defer h.close(.label);
            try h.text(cfg.to_label);
            try h.open(.input, .{ .type = "date", .name = cfg.to_name, .value = cfg.to });
        }
        {
            try h.open(.button, .{ .class = "btn btn-primary", .type = "submit" });
            defer h.close(.button);
            try h.text(cfg.apply_label);
        }
    }
}

test presets {
    const inst = try zeit.instantFromText(.iso8601, "2026-05-22T12:00:00Z", &zeit.utc);
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const p = try presets(fba.allocator(), inst);

    try std.testing.expectEqual(@as(usize, 7), p.len);
    try std.testing.expectEqualStrings("This month", p[0].label);
    try std.testing.expectEqualStrings("2026-05-01", p[0].from);
    try std.testing.expectEqualStrings("", p[0].to);
    try std.testing.expectEqualStrings("Last month", p[1].label);
    try std.testing.expectEqualStrings("2026-04-01", p[1].from);
    try std.testing.expectEqualStrings("2026-04-30", p[1].to);
    try std.testing.expectEqualStrings("2026-01-01", p[2].from);
    try std.testing.expectEqualStrings("", p[2].to);
    try std.testing.expectEqualStrings("2025-01-01", p[3].from);
    try std.testing.expectEqualStrings("2025-12-31", p[3].to);
    try std.testing.expectEqualStrings("2026-04-22", p[4].from);
    try std.testing.expectEqualStrings("2026-05-22", p[4].to);
    try std.testing.expectEqualStrings("2026-02-21", p[5].from);
    try std.testing.expectEqualStrings("2026-05-22", p[5].to);
    try std.testing.expectEqualStrings("All", p[6].label);
    try std.testing.expectEqualStrings("", p[6].from);
    try std.testing.expectEqualStrings("", p[6].to);
}

