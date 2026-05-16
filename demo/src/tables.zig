const zigweb = @import("zigweb");

pub const migrate = zigweb.tables.migrate;
pub const Table = zigweb.tables.Table;
pub const initTables = zigweb.tables.initTables;

// Re-export base tables
pub const credentials = zigweb.tables.credentials;
pub const sessions = zigweb.tables.sessions;

// App-specific tables
pub const notes: Table = .{
    .schema =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\  id          INTEGER PRIMARY KEY,
    \\  credential  INTEGER NOT NULL REFERENCES credentials(id),
    \\  content     TEXT NOT NULL DEFAULT '',
    \\  status      TEXT NOT NULL DEFAULT 'open',
    \\  category    TEXT NOT NULL DEFAULT 'general',
    \\  created     INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    ,
};
