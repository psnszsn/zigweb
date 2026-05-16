pub const QueryParams = struct {
    status: ?[]const u8 = null,
    category: ?[]const u8 = null,
    q: ?[]const u8 = null,
    created_from: ?[]const u8 = null,
    created_to: ?[]const u8 = null,
    page: usize = 1,
    size: usize = 10,

    pub fn from_query(query: []const u8, buf: []u8) QueryParams {
        var f = query_parse.parseQueryInto(QueryParams, query, buf);
        if (f.page == 0) f.page = 1;
        if (f.size == 0) f.size = 10;
        return f;
    }
    fn filterValues(qp: *const QueryParams) [filters_spec.len]Table.FilterValue {
        return .{
            .{ .choice = qp.status },
            .{ .choice = qp.category },
            .{ .text = qp.q },
            .{ .date_range = .{ .from = qp.created_from, .to = qp.created_to } },
        };
    }
};

pub const filters_spec: []const Table.FilterSpec = &.{
    .{
        .key = "status",
        .label = "Status",
        .pinned = true,
        .kind = .{ .choice = .{ .multi = true, .options = &.{
            .{ .value = "open", .label = "Open" },
            .{ .value = "done", .label = "Done" },
            .{ .value = "archived", .label = "Archived" },
        } } },
    },
    .{
        .key = "category",
        .label = "Category",
        .pinned = true,
        .kind = .{ .choice = .{ .multi = false, .options = &.{
            .{ .value = "general", .label = "General" },
            .{ .value = "work", .label = "Work" },
            .{ .value = "personal", .label = "Personal" },
        } } },
    },
    .{
        .key = "q",
        .label = "Search",
        .pinned = false,
        .kind = .{ .text = .{ .placeholder = "Search content…" } },
    },
    .{
        .key = "created",
        .label = "Date",
        .pinned = false,
        .kind = .date_range,
    },
};

const NotesQuery = Queries.get_type(.notes_list_filtered);

fn page(h: Html, qp: QueryParams) !void {
    {
        try h.open(.h1, .{});
        defer h.close(.h1);
        try h.text("Notes");
    }

    // Add note form
    {
        try h.open(.form, .{ .method = "POST", .action = "/notes/add", .class = "add-form" });
        defer h.close(.form);

        try h.open(.textarea, .{ .name = "content", .placeholder = "Write a note...", .rows = "2", .required = true });
        h.close(.textarea);

        {
            try h.open(.div, .{ .class = "add-form-row" });
            defer h.close(.div);

            {
                try h.open(.select, .{ .name = "category" });
                defer h.close(.select);
                inline for (.{ "general", "work", "personal" }) |c| {
                    try h.open(.option, .{ .value = c });
                    defer h.close(.option);
                    try h.text(c);
                }
            }

            try h.open(.button, .{ .type = "submit" });
            defer h.close(.button);
            try h.text("Add Note");
        }
    }

    try renderTableRegion(h, qp);
}

const notes_columns: []const Table.ColumnSpec = &.{
    .{ .name = "content", .header = "Content" },
    .{ .name = "status", .header = "Status" },
    .{ .name = "category", .header = "Category" },
    .{ .name = "created", .header = "Created" },
    .{ .name = "id", .header = "" },
};

fn renderNotesCell(row: NotesQuery.Row, field: std.meta.FieldEnum(NotesQuery.Cols), h: *zigweb.Html) anyerror!void {
    switch (field) {
        .content => try h.text(row.textNoDupe(.content)),
        .status => {
            try h.open(.span, .{ .class = "badge" });
            defer h.close(.span);
            try h.text(row.textNoDupe(.status));
        },
        .category => try h.text(row.textNoDupe(.category)),
        .created => {
            const ts = row.get(.created);
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
            const ymd = epoch.getEpochDay().calculateYearDay();
            const md = ymd.calculateMonthDay();
            try h.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ ymd.year, @intFromEnum(md.month), md.day_index + 1 });
        },
        .id => {
            const id = row.get(.id);
            var post_buf: [64]u8 = undefined;
            const post_url = std.fmt.bufPrint(&post_buf, "/notes/{d}/toggle", .{id}) catch return;
            try h.open(.button, .{
                .class = "btn",
                .hx = .{
                    .post = post_url,
                    .target = "#notes-table",
                    .swap = "outerHTML",
                    .include = "closest #notes-table",
                },
                .title = "Toggle done",
            });
            defer h.close(.button);
            try h.text("✓");
        },
    }
}

/// Render only the swap-target region (`#notes-table`).
pub fn renderTableRegion(h: Html, qp: QueryParams) !void {
    const credential = h.session orelse return;
    const offset: i64 = @intCast((qp.page - 1) * qp.size);
    const limit: i64 = @intCast(qp.size);

    var status_buf: [128]u8 = undefined;
    const status_json = Table.choiceToJsonArray(&status_buf, qp.status);

    var rows = h.app.qs.notes_list_filtered.run(@src(), h.app.db.*, .{
        .credential = credential,
        .status = status_json,
        .category = qp.category,
        .q = qp.q,
        .created_from = qp.created_from,
        .created_to = qp.created_to,
        .limit = limit,
        .offset = offset,
    });
    defer rows.deinit();

    const count_row = h.app.qs.notes_count_filtered.run(@src(), h.app.db.*, .{
        .credential = credential,
        .status = status_json,
        .category = qp.category,
        .q = qp.q,
        .created_from = qp.created_from,
        .created_to = qp.created_to,
    }) orelse return;
    defer count_row.deinit();
    const total: usize = @intCast(count_row.get(.total));

    const filter_values = qp.filterValues();

    const spec = Table.forRows(NotesQuery, renderNotesCell, null, &rows, .{
        .base_path = "/notes",
        .table_id = "notes-table",
        .filters_spec = filters_spec,
        .filter_values = &filter_values,
        .page = qp.page,
        .size = qp.size,
        .columns = notes_columns,
    });

    try h.open(.div, .{ .id = "notes-table" });
    defer h.close(.div);
    try spec.render(h.inner, total);
}

pub fn handle_request(
    request: *std.http.Server.Request,
    io: std.Io,
    app: *const App,
    session: i64,
    t: Target,
) !void {
    var qbuf: [1024]u8 = undefined;
    const qp = QueryParams.from_query(t.query, &qbuf);

    switch (request.head.method) {
        .GET => {
            if (std.mem.eql(u8, t.path, "/notes")) {
                if (zigweb.Table.isHxRequest(request)) return renderRegion(request, app, session, qp);
                var resp: zigweb.server.Response = .{};
                try resp.init(request, .{ .respond_options = zigweb.server.html_page_headers });
                var h = resp.html();
                try root.renderPageWith(QueryParams, &h, page, qp, session, io, app);
                return resp.end();
            }
            if (std.mem.startsWith(u8, t.path, "/notes/add-pill/")) {
                const key = t.path["/notes/add-pill/".len..];
                if (!Table.hasFilterKey(filters_spec, key)) return zigweb.server.notFound(request);
                const filter_values = qp.filterValues();
                var resp: zigweb.server.Response = .{};
                try resp.init(request, .{ .respond_options = zigweb.server.html_partial_headers });
                var h = resp.html();
                try Table.renderOneFilterPill(&h, "/notes", "notes-table", filters_spec, &filter_values, qp.page, qp.size, key);
                return resp.end();
            }
        },
        .POST => {
            if (std.mem.eql(u8, t.path, "/notes/add")) return handleAdd(request, app, session);
            if (std.mem.startsWith(u8, t.path, "/notes/") and std.mem.endsWith(u8, t.path, "/toggle")) {
                const id_str = t.path["/notes/".len .. t.path.len - "/toggle".len];
                const id = std.fmt.parseInt(i64, id_str, 10) catch return zigweb.server.notFound(request);
                app.qs.toggle_note_status.run(@src(), app.db.*, .{ session, id });
                return renderRegion(request, app, session, qp);
            }
        },
        else => {},
    }

    return zigweb.server.notFound(request);
}

/// Render `#notes-table` as an HTMX partial. Used by GET /notes
/// (HX-Request) and by POST /notes/<id>/toggle after the mutation.
fn renderRegion(
    request: *std.http.Server.Request,
    app: *const App,
    session: i64,
    qp: QueryParams,
) !void {
    var resp: zigweb.server.Response = .{};
    try resp.init(request, .{ .respond_options = zigweb.server.html_partial_headers });
    var inner = resp.html();
    const h: Html = .{ .inner = &inner, .app = app, .io = undefined, .session = session };
    try renderTableRegion(h, qp);
    try resp.end();
}

fn handleAdd(request: *std.http.Server.Request, app: *const App, session: i64) !void {
    var read_buf: [4096]u8 = undefined;
    const reader = request.readerExpectNone(&read_buf);
    var fields = query_parse.FormIterator.init(reader);

    var content_buf: [4096]u8 = undefined;
    var content_w = std.Io.Writer.fixed(&content_buf);
    var content_seen = false;

    var category_buf: [64]u8 = undefined;
    var category_w = std.Io.Writer.fixed(&category_buf);
    var category_seen = false;

    while (fields.next() catch {
        try request.respond("Bad Request", .{ .status = .bad_request });
        return;
    }) |f| {
        if (f.eql_key("content")) {
            _ = try f.value_reader.streamRemaining(&content_w);
            content_seen = true;
        } else if (f.eql_key("category")) {
            _ = try f.value_reader.streamRemaining(&category_w);
            category_seen = true;
        }
    }

    if (!content_seen) {
        try request.respond("Missing content", .{ .status = .bad_request });
        return;
    }

    const category: []const u8 = if (category_seen) category_w.buffered() else "general";
    app.qs.insert_note.run(@src(), app.db.*, .{ session, content_w.buffered(), category });
    try zigweb.server.redirect(request, "/notes");
}

const zigweb = @import("zigweb");
const std = @import("std");
const root = @import("root.zig");
const Html = root.Html;
const main = @import("../main.zig");
const App = main.App;
const Target = main.Target;
const Queries = @import("../Queries.zig");
const Table = zigweb.Table;
const query_parse = zigweb.query_parse;
