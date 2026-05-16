const std = @import("std");
const Database = @import("zigweb").Database;

notes_list_filtered: Database.Query(
    \\SELECT id, content, status, category, created
    \\FROM notes
    \\WHERE credential = :credential
    \\  AND (:status IS NULL OR status IN (SELECT value FROM json_each(:status)))
    \\  AND (:category IS NULL OR category = :category)
    \\  AND (:q IS NULL OR content LIKE '%' || :q || '%')
    \\  AND (:created_from IS NULL OR created >= unixepoch(:created_from || 'T00:00:00Z'))
    \\  AND (:created_to   IS NULL OR created <= unixepoch(:created_to   || 'T23:59:59Z'))
    \\ORDER BY created DESC, id DESC
    \\LIMIT :limit OFFSET :offset
,
    .{
        .kind = .rows,
        .cols = struct {
            id: i64,
            content: void,
            status: void,
            category: void,
            created: i64,
        },
        .args = struct {
            credential: i64,
            status: ?[]const u8,
            category: ?[]const u8,
            q: ?[]const u8,
            created_from: ?[]const u8,
            created_to: ?[]const u8,
            limit: i64,
            offset: i64,
        },
    },
),
notes_count_filtered: Database.Query(
    \\SELECT COUNT(*) AS total
    \\FROM notes
    \\WHERE credential = :credential
    \\  AND (:status IS NULL OR status IN (SELECT value FROM json_each(:status)))
    \\  AND (:category IS NULL OR category = :category)
    \\  AND (:q IS NULL OR content LIKE '%' || :q || '%')
    \\  AND (:created_from IS NULL OR created >= unixepoch(:created_from || 'T00:00:00Z'))
    \\  AND (:created_to   IS NULL OR created <= unixepoch(:created_to   || 'T23:59:59Z'))
,
    .{
        .kind = .row,
        .cols = struct { total: i64 },
        .args = struct {
            credential: i64,
            status: ?[]const u8,
            category: ?[]const u8,
            q: ?[]const u8,
            created_from: ?[]const u8,
            created_to: ?[]const u8,
        },
    },
),
insert_note: Database.Query(
    "INSERT INTO notes (credential, content, category) VALUES (?, ?, ?)",
    .{ .kind = .exec, .args = struct { i64, []const u8, []const u8 } },
),
toggle_note_status: Database.Query(
    \\UPDATE notes
    \\SET status = CASE status
    \\  WHEN 'open' THEN 'done'
    \\  WHEN 'done' THEN 'archived'
    \\  ELSE 'open'
    \\END
    \\WHERE credential = ? AND id = ?
,
    .{ .kind = .exec, .args = struct { i64, i64 } },
),

pub fn get_type(comptime field: std.meta.FieldEnum(@This())) type {
    return @FieldType(@This(), @tagName(field));
}
