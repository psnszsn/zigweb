pub const Database = @import("Database.zig");
pub const tables = @import("Database/tables.zig");
pub const migrate = @import("Database/migrate.zig");
pub const Html = @import("Html.zig");
pub const Auth = @import("auth.zig");
pub const server = @import("server.zig");
pub const Table = @import("Table.zig");
pub const query_parse = @import("query_parse.zig");
pub const zqlite = @import("zqlite");
pub const cbor = @import("cbor");

// Pull each file's `test` blocks into `zig build test` — a plain
// re-export above isn't enough for the test runner to discover them.
test {
    _ = Table;
    _ = query_parse;
}
