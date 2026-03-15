const root = @import("root.zig");
const Html = root.Html;

pub fn home(h: Html) !void {
    if (h.session != null) {
        try h.open(.h1, .{});
        defer h.close(.h1);
        try h.text("Welcome to ZigWeb Demo");
    } else {
        {
            try h.open(.h1, .{});
            defer h.close(.h1);
            try h.text("ZigWeb Demo");
        }
        {
            try h.open(.p, .{});
            defer h.close(.p);
            try h.text("Sign in with a passkey to get started.");
        }
        {
            try h.open(.button, .{ .id = "btn-register" });
            defer h.close(.button);
            try h.text("Register");
        }
        {
            try h.open(.button, .{ .id = "btn-login" });
            defer h.close(.button);
            try h.text("Login");
        }
    }
}
