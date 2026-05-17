//! Filterable, paginated HTML table renderer.

const Table = @This();

base_path: []const u8,
table_id: []const u8,
filters_spec: []const FilterSpec,
filter_values: []const FilterValue,
page: usize,
size: usize,
columns: []const ColumnSpec,

rows_ctx: *anyopaque,
next_row: *const fn (rows_ctx: *anyopaque, out: *zqlite.Row) bool,
render_cell: *const fn (row: *zqlite.Row, column: []const u8, h: *Html) anyerror!void,
/// Set via the `rowIdFn` arg to `forRows` to emit `<tr id="…">` for
/// htmx-targeted partial swaps. Returned slice must alias `buf`.
row_id_fn: ?*const fn (buf: []u8, row: *zqlite.Row) []const u8 = null,

pub fn forRows(
    comptime QueryT: type,
    comptime renderCellFn: fn (QueryT.Row, std.meta.FieldEnum(QueryT.Cols), *Html) anyerror!void,
    comptime rowIdFn: ?fn (buf: []u8, row: QueryT.Row) []const u8,
    rows: anytype,
    opts: struct {
        base_path: []const u8,
        table_id: []const u8,
        filters_spec: []const FilterSpec,
        filter_values: []const FilterValue,
        page: usize,
        size: usize,
        columns: []const ColumnSpec,
    },
) Table {
    const Iter = @typeInfo(@TypeOf(rows)).pointer.child;
    const Field = std.meta.FieldEnum(QueryT.Cols);
    const adapter = struct {
        fn next(ctx: *anyopaque, out: *zqlite.Row) bool {
            const it: *Iter = @ptrCast(@alignCast(ctx));
            const r = it.next() orelse return false;
            out.* = r.row;
            return true;
        }
        fn cell(slot: *zqlite.Row, column: []const u8, h: *Html) anyerror!void {
            const r: QueryT.Row = .{ .row = slot.* };
            const field = std.meta.stringToEnum(Field, column) orelse return error.UnknownColumn;
            try renderCellFn(r, field, h);
        }
        fn rid(buf: []u8, slot: *zqlite.Row) []const u8 {
            const r: QueryT.Row = .{ .row = slot.* };
            return rowIdFn.?(buf, r);
        }
    };
    return .{
        .base_path = opts.base_path,
        .table_id = opts.table_id,
        .filters_spec = opts.filters_spec,
        .filter_values = opts.filter_values,
        .page = opts.page,
        .size = opts.size,
        .columns = opts.columns,
        .rows_ctx = rows,
        .next_row = adapter.next,
        .render_cell = adapter.cell,
        .row_id_fn = if (rowIdFn != null) adapter.rid else null,
    };
}

pub fn render(self: Table, h: *Html, total: usize) !void {
    try renderFilterPanel(h, self.base_path, self.table_id, self.filters_spec, self.filter_values, self.page, self.size);
    try self.renderTableBody(h);
    try renderSpecPagination(h, self.base_path, self.table_id, self.filters_spec, self.filter_values, self.page, self.size, .{
        .page = self.page,
        .size = self.size,
        .total = total,
    });
}

fn renderTableBody(self: Table, h: *Html) !void {
    try h.open(.div, .{ .class = "table-scroll" });
    defer h.close(.div);
    try h.open(.table, .{});
    defer h.close(.table);

    {
        try h.open(.thead, .{});
        defer h.close(.thead);
        try h.open(.tr, .{});
        defer h.close(.tr);
        for (self.columns) |col| {
            try h.open(.th, .{});
            defer h.close(.th);
            try h.text(col.header);
        }
    }

    try h.open(.tbody, .{});
    defer h.close(.tbody);

    var slot: zqlite.Row = undefined;
    var any: bool = false;
    while (self.next_row(self.rows_ctx, &slot)) {
        any = true;
        if (self.row_id_fn) |rid_fn| {
            var rid_buf: [64]u8 = undefined;
            try h.open(.tr, .{ .id = rid_fn(&rid_buf, &slot) });
        } else {
            try h.open(.tr, .{});
        }
        defer h.close(.tr);
        for (self.columns) |col| {
            try h.open(.td, .{});
            defer h.close(.td);
            try self.render_cell(&slot, col.name, h);
        }
    }

    if (!any) {
        try h.open(.tr, .{});
        defer h.close(.tr);
        try h.open(.td, .{ .colspan = try h.fmt("{d}", .{self.columns.len}) });
        defer h.close(.td);
        try h.text("No results");
    }
}

pub const PaginationSpec = struct {
    page: usize,
    size: usize,
    total: usize,
};

pub const ChoiceOption = struct {
    value: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
};

/// Shared tag set for `FilterKind` and `FilterValue` — same variant
/// names so a switch on the kind matches a switch on the value.
pub const FilterTag = enum { choice, text_dropdown, search, tribool, date_range };

pub const FilterKind = union(FilterTag) {
    choice: struct {
        options: []const ChoiceOption,
        multi: bool = false,
    },
    text_dropdown: struct { placeholder: []const u8 = "Search…" },
    /// Inline input — no dropdown, renders as a flush search bar.
    search: struct { placeholder: []const u8 = "Search…" },
    tribool: struct {
        yes_label: []const u8 = "Yes",
        no_label: []const u8 = "No",
    },
    date_range,
};

pub const FilterSpec = struct {
    key: []const u8,
    label: []const u8,
    kind: FilterKind,
    /// Pinned filters are always visible; others only appear when set
    /// or when added via "+ Add filter".
    pinned: bool = false,
    /// Treats this value as the default — no pill, and URL omits the key.
    default_value: ?[]const u8 = null,
};

/// Runtime value parallel to a `FilterSpec`. The active variant must
/// match `FilterSpec.kind`; caller passes a `[]const FilterValue`
/// slice the same length as the spec.
pub const FilterValue = union(FilterTag) {
    choice: ?[]const u8, // CSV (`"open,done"`); null = not set
    text_dropdown: ?[]const u8,
    search: ?[]const u8,
    tribool: ?bool,
    date_range: DateRange,

    pub const DateRange = struct {
        from: ?[]const u8 = null,
        to: ?[]const u8 = null,
    };

    pub fn empty(kind: FilterKind) FilterValue {
        return switch (kind) {
            .choice => .{ .choice = null },
            .text_dropdown => .{ .text_dropdown = null },
            .search => .{ .search = null },
            .tribool => .{ .tribool = null },
            .date_range => .{ .date_range = .{} },
        };
    }
};

pub const BuildUrlOverride = union(enum) {
    none,
    set_page: usize,
    /// `op = .toggle` flips membership in a multi-choice CSV;
    /// `op = .set` overwrites for any kind.
    set_filter: struct {
        key: []const u8,
        value: ?[]const u8,
        op: enum { set, toggle } = .set,
    },
    clear_filter: struct { key: []const u8 },
};

// ── Helpers ─────────────────────────────────────────────────────────

pub fn choiceContains(field: ?[]const u8, value: []const u8) bool {
    const s = field orelse return false;
    if (s.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, s, ',');
    while (it.next()) |tok| if (std.mem.eql(u8, tok, value)) return true;
    return false;
}

pub fn choiceToggle(buf: []u8, field: ?[]const u8, value: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var first = true;
    var found = false;
    if (field) |s| {
        var it = std.mem.tokenizeScalar(u8, s, ',');
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, value)) {
                found = true;
                continue;
            }
            if (!first) w.writeByte(',') catch break;
            w.writeAll(tok) catch break;
            first = false;
        }
    }
    if (!found) {
        if (!first) w.writeByte(',') catch return buf[0..w.end];
        w.writeAll(value) catch return buf[0..w.end];
    }
    return buf[0..w.end];
}

/// Tokens come from untrusted URL input; JSON-escape each so a `"`
/// or `\` doesn't produce malformed JSON (which would `db.fatal`).
pub fn choiceToJsonArray(buf: []u8, csv: ?[]const u8) ?[]const u8 {
    const s = csv orelse return null;
    if (s.len == 0) return null;
    var w = std.Io.Writer.fixed(buf);
    w.writeByte('[') catch return null;
    var it = std.mem.tokenizeScalar(u8, s, ',');
    var first = true;
    while (it.next()) |tok| {
        if (!first) w.writeByte(',') catch return null;
        std.json.Stringify.encodeJsonString(tok, .{}, &w) catch return null;
        first = false;
    }
    w.writeByte(']') catch return null;
    return buf[0..w.end];
}

pub fn isHxRequest(request: *std.http.Server.Request) bool {
    var iter = request.iterateHeaders();
    while (iter.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "hx-request")) {
            return std.mem.eql(u8, h.value, "true");
        }
    }
    return false;
}

pub fn hasFilterKey(spec: []const FilterSpec, key: []const u8) bool {
    for (spec) |f| if (std.mem.eql(u8, f.key, key)) return true;
    return false;
}

/// Decoded text is written into `qp_buf` and returned slices alias
/// it — `qp_buf` must outlive the values. `out.len >= spec.len`.
pub fn parseFilterValues(
    spec: []const FilterSpec,
    query: []const u8,
    qp_buf: []u8,
    out: []FilterValue,
) struct { page: ?usize, size: ?usize } {
    std.debug.assert(out.len >= spec.len);
    for (spec, out[0..spec.len]) |f, *v| v.* = FilterValue.empty(f.kind);

    var page: ?usize = null;
    var size: ?usize = null;
    var cursor: usize = 0;

    var reader = std.Io.Reader.fixed(query);
    var it = query_parse.FormIterator.init(&reader);
    while (it.next() catch null) |pair| {
        if (pair.eql_key("page")) {
            page = decodeUsize(pair) orelse continue;
            continue;
        }
        if (pair.eql_key("size")) {
            size = decodeUsize(pair) orelse continue;
            continue;
        }
        for (spec, out[0..spec.len]) |f, *v| {
            const slot: enum { none, plain, from, to } = blk: {
                switch (f.kind) {
                    .date_range => {
                        var key_buf: [128]u8 = undefined;
                        const fk = std.fmt.bufPrint(&key_buf, "{s}_from", .{f.key}) catch break :blk .none;
                        if (pair.eql_key(fk)) break :blk .from;
                        const tk = std.fmt.bufPrint(&key_buf, "{s}_to", .{f.key}) catch break :blk .none;
                        if (pair.eql_key(tk)) break :blk .to;
                        break :blk .none;
                    },
                    else => break :blk if (pair.eql_key(f.key)) .plain else .none,
                }
            };
            if (slot == .none) continue;

            var w = std.Io.Writer.fixed(qp_buf[cursor..]);
            _ = pair.value_reader.streamRemaining(&w) catch break;
            const decoded = qp_buf[cursor..][0..w.end];
            cursor += w.end;

            switch (f.kind) {
                .choice => v.* = .{ .choice = if (decoded.len == 0) null else decoded },
                .text_dropdown => v.* = .{ .text_dropdown = if (decoded.len == 0) null else decoded },
                .search => v.* = .{ .search = if (decoded.len == 0) null else decoded },
                .tribool => {
                    if (std.mem.eql(u8, decoded, "true") or std.mem.eql(u8, decoded, "1")) {
                        v.* = .{ .tribool = true };
                    } else if (std.mem.eql(u8, decoded, "false") or std.mem.eql(u8, decoded, "0")) {
                        v.* = .{ .tribool = false };
                    }
                },
                .date_range => switch (slot) {
                    .from => v.date_range.from = if (decoded.len == 0) null else decoded,
                    .to => v.date_range.to = if (decoded.len == 0) null else decoded,
                    else => unreachable,
                },
            }
            break;
        }
    }
    return .{ .page = page, .size = size };
}

fn decodeUsize(pair: *query_parse.FormIterator.Pair) ?usize {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    _ = pair.value_reader.streamRemaining(&w) catch return null;
    return std.fmt.parseInt(usize, w.buffered(), 10) catch null;
}

// ── URL builder ─────────────────────────────────────────────────────

/// Page resets to 1 on filter mutations and is preserved on `set_page`.
pub fn buildUrlFromSpec(
    buf: []u8,
    base_path: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
    override: BuildUrlOverride,
) []const u8 {
    std.debug.assert(values.len >= spec.len);
    var w = std.Io.Writer.fixed(buf);
    w.writeAll(base_path) catch return overflow(base_path, buf.len);
    var sep: u8 = '?';

    for (spec, values[0..spec.len]) |f, v| {
        switch (f.kind) {
            .choice => |c| {
                var toggle_buf: [256]u8 = undefined;
                const cur = v.choice;
                const new_value: ?[]const u8 = blk: {
                    switch (override) {
                        .clear_filter => |cf| if (std.mem.eql(u8, cf.key, f.key)) break :blk null,
                        .set_filter => |sf| if (std.mem.eql(u8, sf.key, f.key)) switch (sf.op) {
                            .set => break :blk sf.value,
                            .toggle => {
                                if (!c.multi) break :blk sf.value;
                                const vv = sf.value orelse break :blk cur;
                                const out = choiceToggle(&toggle_buf, cur, vv);
                                if (out.len == 0) break :blk null;
                                break :blk out;
                            },
                        },
                        else => {},
                    }
                    break :blk cur;
                };
                writeFilterParam(&w, &sep, base_path, buf.len, f, new_value) orelse return overflow(base_path, buf.len);
            },
            .text_dropdown => {
                const cur = v.text_dropdown;
                const new_value: ?[]const u8 = blk: {
                    switch (override) {
                        .clear_filter => |cf| if (std.mem.eql(u8, cf.key, f.key)) break :blk null,
                        .set_filter => |sf| if (std.mem.eql(u8, sf.key, f.key)) break :blk sf.value,
                        else => {},
                    }
                    break :blk cur;
                };
                writeFilterParam(&w, &sep, base_path, buf.len, f, new_value) orelse return overflow(base_path, buf.len);
            },
            .search => {
                const cur = v.search;
                const new_value: ?[]const u8 = blk: {
                    switch (override) {
                        .clear_filter => |cf| if (std.mem.eql(u8, cf.key, f.key)) break :blk null,
                        .set_filter => |sf| if (std.mem.eql(u8, sf.key, f.key)) break :blk sf.value,
                        else => {},
                    }
                    break :blk cur;
                };
                writeFilterParam(&w, &sep, base_path, buf.len, f, new_value) orelse return overflow(base_path, buf.len);
            },
            .tribool => {
                const cur = v.tribool;
                const new_value: ?bool = blk: {
                    switch (override) {
                        .clear_filter => |cf| if (std.mem.eql(u8, cf.key, f.key)) break :blk null,
                        .set_filter => |sf| if (std.mem.eql(u8, sf.key, f.key)) {
                            const vv = sf.value orelse break :blk null;
                            if (std.mem.eql(u8, vv, "true")) break :blk true;
                            if (std.mem.eql(u8, vv, "false")) break :blk false;
                            break :blk null;
                        },
                        else => {},
                    }
                    break :blk cur;
                };
                if (new_value) |b| {
                    w.writeByte(sep) catch return overflow(base_path, buf.len);
                    sep = '&';
                    w.print("{s}={s}", .{ f.key, if (b) "true" else "false" }) catch return overflow(base_path, buf.len);
                }
            },
            .date_range => {
                const cleared = switch (override) {
                    .clear_filter => |cf| std.mem.eql(u8, cf.key, f.key),
                    else => false,
                };
                if (cleared) continue;
                const dr = v.date_range;
                if (dr.from) |fv| if (fv.len > 0) {
                    w.writeByte(sep) catch return overflow(base_path, buf.len);
                    sep = '&';
                    w.print("{s}_from=", .{f.key}) catch return overflow(base_path, buf.len);
                    writeEncodedTo(&w, fv);
                };
                if (dr.to) |tv| if (tv.len > 0) {
                    w.writeByte(sep) catch return overflow(base_path, buf.len);
                    sep = '&';
                    w.print("{s}_to=", .{f.key}) catch return overflow(base_path, buf.len);
                    writeEncodedTo(&w, tv);
                };
            },
        }
    }

    const eff_page: usize = switch (override) {
        .set_page => |p| p,
        .none => page,
        else => 1,
    };
    w.print("{c}page={d}&size={d}", .{ sep, eff_page, size }) catch return overflow(base_path, buf.len);

    return buf[0..w.end];
}

fn writeFilterParam(
    w: *std.Io.Writer,
    sep: *u8,
    base_path: []const u8,
    cap: usize,
    f: FilterSpec,
    value: ?[]const u8,
) ?void {
    _ = base_path;
    _ = cap;
    const v = value orelse return {};
    if (v.len == 0) return {};
    if (f.default_value) |dv| if (std.mem.eql(u8, v, dv)) return {};
    w.writeByte(sep.*) catch return null;
    sep.* = '&';
    w.writeAll(f.key) catch return null;
    w.writeByte('=') catch return null;
    writeEncodedTo(w, v);
    return {};
}

fn writeEncodedTo(w: *std.Io.Writer, raw: []const u8) void {
    (std.Uri.Component{ .raw = raw }).formatEscaped(w) catch {};
}

fn overflow(base: []const u8, cap: usize) []const u8 {
    std.log.warn("table.buildUrlFromSpec: URL exceeds {d}-byte buffer; falling back to '{s}'", .{ cap, base });
    return base;
}

// ── Filter-state predicates ─────────────────────────────────────────

fn choiceLabelOf(options: []const ChoiceOption, value: []const u8) []const u8 {
    for (options) |opt| {
        if (std.mem.eql(u8, opt.value, value)) return opt.label;
    }
    return value;
}

fn filterSelected(f: FilterSpec, v: FilterValue) bool {
    return switch (f.kind) {
        .choice => blk: {
            const s = v.choice orelse break :blk false;
            if (s.len == 0) break :blk false;
            if (f.default_value) |dv| if (std.mem.eql(u8, s, dv)) break :blk false;
            break :blk true;
        },
        .text_dropdown => blk: {
            const s = v.text_dropdown orelse break :blk false;
            if (s.len == 0) break :blk false;
            if (f.default_value) |dv| if (std.mem.eql(u8, s, dv)) break :blk false;
            break :blk true;
        },
        .search => blk: {
            const s = v.search orelse break :blk false;
            if (s.len == 0) break :blk false;
            if (f.default_value) |dv| if (std.mem.eql(u8, s, dv)) break :blk false;
            break :blk true;
        },
        .tribool => v.tribool != null,
        .date_range => blk: {
            const dr = v.date_range;
            const from_set = if (dr.from) |s| s.len > 0 else false;
            const to_set = if (dr.to) |s| s.len > 0 else false;
            break :blk from_set or to_set;
        },
    };
}

fn filterVisible(f: FilterSpec, v: FilterValue) bool {
    if (f.pinned) return true;
    return filterSelected(f, v);
}

// ── Spec-driven render functions ────────────────────────────────────

pub fn renderFilterPanel(
    h: *Html,
    base_path: []const u8,
    table_id: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
) !void {
    try h.open(.div, .{ .class = "filter-bar" });
    defer h.close(.div);

    var any_hidden = false;
    for (spec, values[0..spec.len], 0..) |f, v, i| {
        if (filterVisible(f, v)) {
            try renderFilterPill(h, base_path, table_id, spec, values, page, size, i);
        } else {
            any_hidden = true;
        }
    }

    if (any_hidden) try renderAddFilter(h, base_path, table_id, spec, values, page, size);
}

pub fn renderOneFilterPill(
    h: *Html,
    base_path: []const u8,
    table_id: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
    key: []const u8,
) !void {
    for (spec, 0..) |f, i| {
        if (std.mem.eql(u8, f.key, key)) {
            try renderFilterPill(h, base_path, table_id, spec, values, page, size, i);
            try h.open(.span, .{
                .id = try h.fmt("add-filter-menu-{s}-{s}", .{ table_id, f.key }),
                .hx = .{ .swap_oob = "delete" },
            });
            h.close(.span);
            return;
        }
    }
}

fn renderFilterPill(
    h: *Html,
    base_path: []const u8,
    table_id: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
    idx: usize,
) !void {
    const f = spec[idx];
    const v = values[idx];

    if (f.kind == .search) {
        try renderSearchPill(h, base_path, table_id, spec, values, size, idx);
        return;
    }

    var hash_buf: [64]u8 = undefined;
    const hash_target = std.fmt.bufPrint(&hash_buf, "#{s}", .{table_id}) catch table_id;

    const selected = filterSelected(f, v);
    const wrap_class: []const u8 = if (selected) "filter-pill is-selected" else "filter-pill";
    try h.open(.div, .{ .class = wrap_class });
    defer h.close(.div);

    var name_buf: [80]u8 = undefined;
    const details_name = std.fmt.bufPrint(&name_buf, "filter-bar-{s}", .{table_id}) catch "filter-bar";

    {
        try h.open(.details, .{ .class = "filter-details", .name = details_name });
        defer h.close(.details);

        {
            try h.open(.summary, .{ .class = "pill-body" });
            defer h.close(.summary);
            try renderPillSummaryText(h, f, v, selected);
        }

        try renderPillPopover(h, base_path, hash_target, spec, values, page, size, idx);
    }

    if (selected) {
        var url_buf: [512]u8 = undefined;
        const clear_url = buildUrlFromSpec(&url_buf, base_path, spec, values, page, size, .{ .clear_filter = .{ .key = f.key } });
        try h.open(.a, .{
            .class = "pill-clear",
            .href = clear_url,
            .hx = .{
                .get = clear_url,
                .target = hash_target,
                .swap = "outerHTML",
                .push_url = "true",
            },
            .title = "Remove filter",
        });
        defer h.close(.a);
        try h.raw("&times;");
    }
}

fn renderSearchPill(
    h: *Html,
    base_path: []const u8,
    table_id: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    size: usize,
    idx: usize,
) !void {
    const f = spec[idx];
    const v = values[idx];
    const sx = f.kind.search;

    var hash_buf: [64]u8 = undefined;
    const hash_target = std.fmt.bufPrint(&hash_buf, "#{s}", .{table_id}) catch table_id;

    try h.open(.form, .{
        .class = "filter-pill search-pill",
        .hx = .{
            .get = base_path,
            .target = hash_target,
            .swap = "outerHTML",
            .push_url = "true",
        },
    });
    defer h.close(.form);

    try h.open(.input, .{
        .type = "search",
        .name = f.key,
        .value = v.search orelse "",
        .placeholder = sx.placeholder,
    });
    try renderHiddenFilterInputs(h, spec, values, f.key);
    try renderHiddenPagination(h, size);
}

fn renderPillSummaryText(h: *Html, f: FilterSpec, v: FilterValue, selected: bool) !void {
    if (!selected) {
        try h.text(f.label);
        return;
    }
    {
        try h.open(.span, .{ .class = "pill-label" });
        defer h.close(.span);
        try h.text(f.label);
        try h.text(":");
    }
    try h.text(" ");
    switch (f.kind) {
        .choice => |c| {
            const csv = v.choice.?;
            if (c.multi) {
                var it = std.mem.tokenizeScalar(u8, csv, ',');
                var n: usize = 0;
                var shown: usize = 0;
                while (it.next()) |tok| : (n += 1) {
                    if (shown < 2) {
                        if (shown > 0) try h.text(", ");
                        try h.text(choiceLabelOf(c.options, tok));
                        shown += 1;
                    }
                }
                if (n > shown) try h.print(", +{d}", .{n - shown});
            } else try h.text(choiceLabelOf(c.options, csv));
        },
        .text_dropdown => try h.text(v.text_dropdown.?),
        .search => unreachable,
        .tribool => |tb| try h.text(if (v.tribool.?) tb.yes_label else tb.no_label),
        .date_range => {
            const from = v.date_range.from orelse "";
            const to = v.date_range.to orelse "";
            if (from.len > 0) try h.text(from);
            if (from.len > 0 and to.len > 0) try h.text(" – ");
            if (to.len > 0) try h.text(to);
        },
    }
}

fn renderPillPopover(
    h: *Html,
    base_path: []const u8,
    hash_target: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
    idx: usize,
) !void {
    const f = spec[idx];
    const v = values[idx];
    switch (f.kind) {
        .choice => |c| {
            try h.open(.div, .{ .class = "dropdown-menu" });
            defer h.close(.div);

            for (c.options) |opt| {
                const active = blk: {
                    if (c.multi) break :blk choiceContains(v.choice, opt.value);
                    if (v.choice) |s| break :blk std.mem.eql(u8, s, opt.value);
                    break :blk false;
                };
                const op_kind: @typeInfo(@TypeOf(@as(BuildUrlOverride, undefined).set_filter)).@"struct".fields[2].type =
                    if (c.multi) .toggle else .set;
                var url_buf: [512]u8 = undefined;
                const url = buildUrlFromSpec(&url_buf, base_path, spec, values, page, size, .{ .set_filter = .{ .key = f.key, .value = opt.value, .op = op_kind } });
                const cls: []const u8 = if (active) "menu-item is-active" else "menu-item";
                try h.open(.a, .{
                    .class = cls,
                    .href = url,
                    .hx = .{
                        .get = url,
                        .target = hash_target,
                        .swap = "outerHTML",
                        .push_url = "true",
                    },
                    .title = opt.description,
                });
                defer h.close(.a);
                if (active) try h.raw("&check; ");
                try h.text(opt.label);
            }
        },
        .tribool => |tb| {
            try h.open(.div, .{ .class = "dropdown-menu" });
            defer h.close(.div);

            const cur = v.tribool;
            const choices = [_]struct { label: []const u8, value: []const u8, match: bool }{
                .{ .label = tb.yes_label, .value = "true", .match = true },
                .{ .label = tb.no_label, .value = "false", .match = false },
            };
            for (choices) |ch| {
                const active = cur != null and cur.? == ch.match;
                var url_buf: [512]u8 = undefined;
                const url = buildUrlFromSpec(&url_buf, base_path, spec, values, page, size, .{ .set_filter = .{ .key = f.key, .value = ch.value } });
                const cls: []const u8 = if (active) "menu-item is-active" else "menu-item";
                try h.open(.a, .{
                    .class = cls,
                    .href = url,
                    .hx = .{
                        .get = url,
                        .target = hash_target,
                        .swap = "outerHTML",
                        .push_url = "true",
                    },
                });
                defer h.close(.a);
                try h.text(ch.label);
            }
        },
        .text_dropdown => |tx| {
            try h.open(.form, .{
                .hx = .{
                    .get = base_path,
                    .target = hash_target,
                    .swap = "outerHTML",
                    .push_url = "true",
                },
                .class = "filter-form",
                .style = "flex-direction: row; gap: 0.5rem; align-items: stretch;",
            });
            defer h.close(.form);

            try h.open(.input, .{
                .id = try h.fmt("filter-input-{s}-{s}", .{ hash_target[1..], f.key }),
                .hx = .{ .preserve = "true" },
                .type = "search",
                .name = f.key,
                .value = v.text_dropdown orelse "",
                .placeholder = tx.placeholder,
            });
            try renderHiddenFilterInputs(h, spec, values, f.key);
            try renderHiddenPagination(h, size);
        },
        .search => unreachable,
        .date_range => {
            try h.open(.form, .{
                .hx = .{
                    .get = base_path,
                    .target = hash_target,
                    .swap = "outerHTML",
                    .push_url = "true",
                },
                .class = "filter-form",
                .style = "flex-direction: row; gap: 0.5rem; align-items: end;",
            });
            defer h.close(.form);

            try h.open(.input, .{
                .type = "date",
                .name = try h.fmt("{s}_from", .{f.key}),
                .value = v.date_range.from orelse "",
            });
            try h.open(.input, .{
                .type = "date",
                .name = try h.fmt("{s}_to", .{f.key}),
                .value = v.date_range.to orelse "",
            });
            try renderHiddenFilterInputs(h, spec, values, f.key);
            try renderHiddenPagination(h, size);
            try h.open(.button, .{ .class = "btn btn-primary", .type = "submit" });
            defer h.close(.button);
            try h.text("Apply");
        },
    }
}

fn renderHiddenPagination(h: *Html, size: usize) !void {
    try h.open(.input, .{ .type = "hidden", .name = "page", .value = "1" });
    try h.open(.input, .{ .type = "hidden", .name = "size", .value = try h.fmt("{d}", .{size}) });
}

fn renderHiddenFilterInputs(
    h: *Html,
    spec: []const FilterSpec,
    values: []const FilterValue,
    exclude_key: []const u8,
) !void {
    for (spec, values[0..spec.len]) |f, v| {
        if (std.mem.eql(u8, f.key, exclude_key)) continue;
        switch (f.kind) {
            .choice => if (v.choice) |s| if (s.len > 0) {
                try h.open(.input, .{ .type = "hidden", .name = f.key, .value = s });
            },
            .text_dropdown => if (v.text_dropdown) |s| if (s.len > 0) {
                try h.open(.input, .{ .type = "hidden", .name = f.key, .value = s });
            },
            .search => if (v.search) |s| if (s.len > 0) {
                try h.open(.input, .{ .type = "hidden", .name = f.key, .value = s });
            },
            .tribool => if (v.tribool) |b| {
                try h.open(.input, .{ .type = "hidden", .name = f.key, .value = if (b) "true" else "false" });
            },
            .date_range => {
                if (v.date_range.from) |s| if (s.len > 0) {
                    try h.open(.input, .{
                        .type = "hidden",
                        .name = try h.fmt("{s}_from", .{f.key}),
                        .value = s,
                    });
                };
                if (v.date_range.to) |s| if (s.len > 0) {
                    try h.open(.input, .{
                        .type = "hidden",
                        .name = try h.fmt("{s}_to", .{f.key}),
                        .value = s,
                    });
                };
            },
        }
    }
}

pub const ColumnSpec = struct {
    name: []const u8,
    header: []const u8,
};

pub fn renderSpecPagination(
    h: *Html,
    base_path: []const u8,
    table_id: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
    p: PaginationSpec,
) !void {
    if (p.total == 0) return;

    var hash_buf: [64]u8 = undefined;
    const hash_target = std.fmt.bufPrint(&hash_buf, "#{s}", .{table_id}) catch table_id;

    try h.open(.div, .{
        .class = "pagination",
        .style = "display: flex; gap: 0.75rem; align-items: center; justify-content: center; margin-top: 1rem;",
    });
    defer h.close(.div);

    if (p.page > 1) {
        var prev_buf: [512]u8 = undefined;
        const prev_href = buildUrlFromSpec(&prev_buf, base_path, spec, values, page, size, .{ .set_page = p.page - 1 });
        try h.open(.a, .{
            .href = prev_href,
            .class = "btn",
            .hx = .{
                .get = prev_href,
                .target = hash_target,
                .swap = "outerHTML",
                .push_url = "true",
            },
        });
        defer h.close(.a);
        try h.text("Prev");
    } else {
        try h.open(.button, .{ .class = "btn", .type = "button", .disabled = true });
        defer h.close(.button);
        try h.text("Prev");
    }

    {
        try h.open(.span, .{
            .class = "pagination-label",
            .style = "color: #666; font-size: 0.85rem;",
        });
        defer h.close(.span);
        const n: usize = (p.page - 1) * p.size + 1;
        const m: usize = @min(p.page * p.size, p.total);
        try h.print("Showing {d}–{d} of {d}", .{ n, m, p.total });
    }

    if (p.page * p.size < p.total) {
        var next_buf: [512]u8 = undefined;
        const next_href = buildUrlFromSpec(&next_buf, base_path, spec, values, page, size, .{ .set_page = p.page + 1 });
        try h.open(.a, .{
            .href = next_href,
            .class = "btn",
            .hx = .{
                .get = next_href,
                .target = hash_target,
                .swap = "outerHTML",
                .push_url = "true",
            },
        });
        defer h.close(.a);
        try h.text("Next");
    } else {
        try h.open(.button, .{ .class = "btn", .type = "button", .disabled = true });
        defer h.close(.button);
        try h.text("Next");
    }
}

pub fn renderAddFilter(
    h: *Html,
    base_path: []const u8,
    table_id: []const u8,
    spec: []const FilterSpec,
    values: []const FilterValue,
    page: usize,
    size: usize,
) !void {
    try h.open(.div, .{ .class = "filter-pill add-filter" });
    defer h.close(.div);

    var name_buf: [80]u8 = undefined;
    const details_name = std.fmt.bufPrint(&name_buf, "filter-bar-{s}", .{table_id}) catch "filter-bar";
    try h.open(.details, .{ .class = "filter-details", .name = details_name });
    defer h.close(.details);

    {
        try h.open(.summary, .{ .class = "pill-body" });
        defer h.close(.summary);
        try h.text("+ Add filter");
    }

    try h.open(.div, .{ .class = "dropdown-menu" });
    defer h.close(.div);

    var qs_buf: [512]u8 = undefined;
    const qs_url = buildUrlFromSpec(&qs_buf, base_path, spec, values, page, size, .none);
    const qs: []const u8 = blk: {
        const q_start = std.mem.findScalar(u8, qs_url, '?') orelse break :blk "";
        break :blk qs_url[q_start..];
    };

    for (spec, values[0..spec.len]) |f, v| {
        if (!filterVisible(f, v)) {
            const url = try h.fmt("{s}/add-pill/{s}{s}", .{ base_path, f.key, qs });
            try h.open(.a, .{
                .id = try h.fmt("add-filter-menu-{s}-{s}", .{ table_id, f.key }),
                .class = "menu-item",
                .href = url,
                .hx = .{
                    .get = url,
                    .target = "closest .filter-pill.add-filter",
                    .swap = "beforebegin",
                },
            });
            defer h.close(.a);
            try h.text(f.label);
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "choiceContains: empty / single / multi / no match" {
    try std.testing.expect(!choiceContains(null, "x"));
    try std.testing.expect(!choiceContains("", "x"));
    try std.testing.expect(choiceContains("x", "x"));
    try std.testing.expect(!choiceContains("x", "y"));
    try std.testing.expect(choiceContains("a,b,c", "b"));
    try std.testing.expect(!choiceContains("a,b,c", "d"));
}

test "choiceToggle: add / remove / last value clears" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a", choiceToggle(&buf, null, "a"));
    try std.testing.expectEqualStrings("a,b", choiceToggle(&buf, "a", "b"));
    try std.testing.expectEqualStrings("a", choiceToggle(&buf, "a,b", "b"));
    try std.testing.expectEqualStrings("", choiceToggle(&buf, "a", "a"));
    try std.testing.expectEqualStrings("b,c", choiceToggle(&buf, "a,b,c", "a"));
    try std.testing.expectEqualStrings("a,c", choiceToggle(&buf, "a,b,c", "b"));
}

test "choiceToJsonArray: null / empty / single / multi" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), choiceToJsonArray(&buf, null));
    try std.testing.expectEqual(@as(?[]const u8, null), choiceToJsonArray(&buf, ""));
    try std.testing.expectEqualStrings("[\"x\"]", choiceToJsonArray(&buf, "x").?);
    try std.testing.expectEqualStrings("[\"a\",\"b\",\"c\"]", choiceToJsonArray(&buf, "a,b,c").?);
}

test "buildUrlFromSpec: choice single set / clear / preserve" {
    const spec: []const FilterSpec = &.{
        .{ .key = "status", .label = "Status", .pinned = true, .kind = .{
            .choice = .{ .multi = false, .options = &.{
                .{ .value = "open", .label = "Open" },
                .{ .value = "closed", .label = "Closed" },
            } },
        } },
    };
    const values: []const FilterValue = &.{.{ .choice = "open" }};
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/x?status=open&page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, values, 1, 50, .none),
    );
    try std.testing.expectEqualStrings(
        "/x?page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, values, 1, 50, .{ .clear_filter = .{ .key = "status" } }),
    );
    try std.testing.expectEqualStrings(
        "/x?status=closed&page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, values, 1, 50, .{ .set_filter = .{ .key = "status", .value = "closed" } }),
    );
}

test "buildUrlFromSpec: multi-choice toggle" {
    const spec: []const FilterSpec = &.{
        .{ .key = "types", .label = "Types", .pinned = true, .kind = .{
            .choice = .{ .multi = true, .options = &.{
                .{ .value = "a", .label = "A" },
                .{ .value = "b", .label = "B" },
            } },
        } },
    };
    const values: []const FilterValue = &.{.{ .choice = "a" }};
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/x?types=a%2Cb&page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, values, 1, 50, .{ .set_filter = .{ .key = "types", .value = "b", .op = .toggle } }),
    );
    try std.testing.expectEqualStrings(
        "/x?page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, values, 1, 50, .{ .set_filter = .{ .key = "types", .value = "a", .op = .toggle } }),
    );
}

test "buildUrlFromSpec: tribool" {
    const spec: []const FilterSpec = &.{
        .{ .key = "flag", .label = "Flag", .pinned = true, .kind = .{ .tribool = .{} } },
    };
    var buf: [128]u8 = undefined;
    const empty: []const FilterValue = &.{.{ .tribool = null }};
    try std.testing.expectEqualStrings(
        "/x?flag=true&page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, empty, 1, 50, .{ .set_filter = .{ .key = "flag", .value = "true" } }),
    );
    const set_true: []const FilterValue = &.{.{ .tribool = true }};
    try std.testing.expectEqualStrings(
        "/x?page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, set_true, 1, 50, .{ .clear_filter = .{ .key = "flag" } }),
    );
}

test "buildUrlFromSpec: date_range emits _from / _to" {
    const spec: []const FilterSpec = &.{
        .{ .key = "created_at", .label = "Created", .pinned = true, .kind = .date_range },
    };
    const values: []const FilterValue = &.{.{ .date_range = .{ .from = "2026-01-01", .to = "2026-01-31" } }};
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/x?created_at_from=2026-01-01&created_at_to=2026-01-31&page=1&size=50",
        buildUrlFromSpec(&buf, "/x", spec, values, 1, 50, .none),
    );
}

const std = @import("std");
const zqlite = @import("zqlite");
const Html = @import("Html.zig");
const Database = @import("Database.zig");
const query_parse = @import("query_parse.zig");
