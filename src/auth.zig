const Auth = @This();
const std = @import("std");
const cbor = @import("cbor");
const zqlite = @import("zqlite");
const Io = std.Io;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64url = std.base64.url_safe_no_pad;
const Database = @import("Database.zig");

const log = std.log.scoped(.auth);

const max_pending = 64;
const challenge_timeout = Io.Duration.fromSeconds(5 * 60);

const PendingChallenge = struct {
    challenge: [32]u8,
    timestamp: Io.Timestamp,
};

pub const Config = struct {
    app_name: []const u8,
    origin: []const u8,
    rp_id: []const u8,
    debug_bypass: bool = false,
    secure_cookie: bool = true,
};

config: Config,
db: *Database,
mutex: *Io.Mutex,
challenge_buf: [max_pending]PendingChallenge = undefined,
pending_challenges: ChallengeList = .empty,
qs: Queries = undefined,

const ChallengeList = std.ArrayList(PendingChallenge);

const Queries = struct {
    insert_credential: Database.Query(
        "INSERT INTO credentials (cred_id, public_key) VALUES (?, ?)",
        .{ .kind = .exec, .args = struct { cred_id: zqlite.Blob, public_key: zqlite.Blob } },
    ),
    select_credential: Database.Query(
        "SELECT id, public_key FROM credentials WHERE cred_id = ?",
        .{ .kind = .row, .cols = struct { id: i64, public_key: []const u8 }, .args = struct { cred_id: zqlite.Blob } },
    ),
    insert_session: Database.Query(
        "INSERT INTO sessions (token, credential) VALUES (?, ?)",
        .{ .kind = .exec, .args = struct { token: zqlite.Blob, credential: i64 } },
    ),
    delete_session: Database.Query(
        "DELETE FROM sessions WHERE token = ?",
        .{ .kind = .exec, .args = struct { token: zqlite.Blob } },
    ),
    select_session: Database.Query(
        "SELECT credential FROM sessions WHERE token = ?",
        .{ .kind = .row, .cols = struct { credential: i64 }, .args = struct { token: zqlite.Blob } },
    ),
};

pub fn init(auth: *Auth, cfg: Config, db: *Database, mtx: *Io.Mutex) void {
    auth.* = .{
        .config = cfg,
        .db = db,
        .mutex = mtx,
    };
    auth.pending_challenges = ChallengeList.initBuffer(&auth.challenge_buf);
    auth.qs = db.initQueries(Queries);
}

pub fn handleRegisterChallenge(auth: *Auth, request: *std.http.Server.Request, io: Io) !void {
    var challenge: [32]u8 = undefined;
    io.random(&challenge);

    const now = Io.Timestamp.now(io, .real);

    {
        auth.mutex.lockUncancelable(io);
        defer auth.mutex.unlock(io);

        auth.evictExpiredChallenges(now);
        if (auth.pending_challenges.capacity == auth.pending_challenges.items.len) {
            _ = auth.pending_challenges.orderedRemove(0);
        }
        auth.pending_challenges.appendAssumeCapacity(.{ .challenge = challenge, .timestamp = now });
    }

    var challenge_b64_buf: [64]u8 = undefined;
    const challenge_b64 = base64url.Encoder.encode(&challenge_b64_buf, &challenge);

    var write_buf: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&write_buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        },
    });

    try body_writer.writer.print(
        \\{{"challenge":"{s}","rp":{{"name":"{s}"}},"pubKeyCredParams":[{{"type":"public-key","alg":-7}}],"authenticatorSelection":{{"userVerification":"preferred","residentKey":"preferred"}},"user":{{"id":"{s}","name":"user","displayName":"User"}}}}
    , .{ challenge_b64, auth.config.app_name, challenge_b64 });
    try body_writer.end();
}

pub fn handleRegister(auth: *Auth, request: *std.http.Server.Request, io: Io) !void {
    var read_buf: [4096]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    const body = readBody(request, &read_buf, &body_buf) orelse {
        try request.respond("Bad Request", .{ .status = .bad_request });
        return;
    };

    const parsed = std.json.parseFromSlice(RegisterRequest, std.heap.smp_allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try request.respond("Invalid JSON", .{ .status = .bad_request });
        return;
    };
    defer parsed.deinit();
    const reg = parsed.value;

    // Decode clientDataJSON
    var client_data_raw: [1024]u8 = undefined;
    const client_data_len = base64url.Decoder.calcSizeForSlice(reg.clientDataJSON) catch {
        try request.respond("Invalid base64", .{ .status = .bad_request });
        return;
    };
    if (client_data_len > client_data_raw.len) {
        try request.respond("clientDataJSON too large", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&client_data_raw, reg.clientDataJSON) catch {
        try request.respond("Invalid base64", .{ .status = .bad_request });
        return;
    };
    const client_data_json = client_data_raw[0..client_data_len];

    // Parse and verify clientDataJSON
    const client_data = std.json.parseFromSlice(ClientData, std.heap.smp_allocator, client_data_json, .{ .ignore_unknown_fields = true }) catch {
        try request.respond("Invalid clientDataJSON", .{ .status = .bad_request });
        return;
    };
    defer client_data.deinit();

    if (!std.mem.eql(u8, client_data.value.type, "webauthn.create")) {
        try request.respond("Wrong type", .{ .status = .bad_request });
        return;
    }
    if (!std.mem.eql(u8, client_data.value.origin, auth.config.origin)) {
        try request.respond("Wrong origin", .{ .status = .bad_request });
        return;
    }

    // Verify challenge
    var challenge_raw: [32]u8 = undefined;
    const chal_len = base64url.Decoder.calcSizeForSlice(client_data.value.challenge) catch {
        try request.respond("Invalid challenge base64", .{ .status = .bad_request });
        return;
    };
    if (chal_len != 32) {
        try request.respond("Invalid challenge length", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&challenge_raw, client_data.value.challenge) catch {
        try request.respond("Invalid challenge base64", .{ .status = .bad_request });
        return;
    };

    // Decode attestationObject (CBOR)
    var att_raw: [2048]u8 = undefined;
    const att_len = base64url.Decoder.calcSizeForSlice(reg.attestationObject) catch {
        try request.respond("Invalid attestation base64", .{ .status = .bad_request });
        return;
    };
    if (att_len > att_raw.len) {
        try request.respond("attestationObject too large", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&att_raw, reg.attestationObject) catch {
        try request.respond("Invalid attestation base64", .{ .status = .bad_request });
        return;
    };
    const att_bytes = att_raw[0..att_len];

    // Parse CBOR attestation object to extract authData
    var auth_data_slice: []const u8 = undefined;
    const att_parsed = parseAttestationObject(att_bytes, &auth_data_slice);
    if (!att_parsed) {
        try request.respond("Invalid attestation object", .{ .status = .bad_request });
        return;
    }

    // Parse authData: rpIdHash(32) + flags(1) + signCount(4) + aaguid(16) + credIdLen(2) + credId + coseKey
    if (auth_data_slice.len < 55) {
        try request.respond("authData too short", .{ .status = .bad_request });
        return;
    }

    // Verify rpIdHash
    var expected_rp_hash: [32]u8 = undefined;
    Sha256.hash(auth.config.rp_id, &expected_rp_hash, .{});
    if (!std.mem.eql(u8, auth_data_slice[0..32], &expected_rp_hash)) {
        try request.respond("rpIdHash mismatch", .{ .status = .bad_request });
        return;
    }

    // Verify flags: UP (bit 0) and AT (bit 6) must be set for registration
    const flags = auth_data_slice[32];
    if (flags & 0x41 != 0x41) {
        try request.respond("Missing UP or AT flag", .{ .status = .bad_request });
        return;
    }

    // aaguid at offset 37..53, credIdLen at 53..55
    const cred_id_len = std.mem.readInt(u16, auth_data_slice[53..55], .big);
    const cred_data_start: usize = 55;
    const cred_data_end = cred_data_start + cred_id_len;

    if (auth_data_slice.len < cred_data_end) {
        try request.respond("authData truncated", .{ .status = .bad_request });
        return;
    }

    const cred_id_bytes = auth_data_slice[cred_data_start..cred_data_end];
    const cose_key_bytes = auth_data_slice[cred_data_end..];

    // Parse COSE key to get public key
    const pub_key = parseCoseKey(cose_key_bytes) catch {
        try request.respond("Invalid COSE key", .{ .status = .bad_request });
        return;
    };

    // Serialize public key to SEC1 uncompressed (65 bytes)
    const sec1 = pub_key.toUncompressedSec1();

    // Consume challenge under lock
    {
        auth.mutex.lockUncancelable(io);
        defer auth.mutex.unlock(io);

        if (!auth.consumeChallenge(challenge_raw, Io.Timestamp.now(io, .real))) {
            try request.respond("Unknown challenge", .{ .status = .bad_request });
            return;
        }
    }

    // DB ops outside lock
    auth.qs.insert_credential.run(@src(), auth.db.*, .{
        .cred_id = zqlite.blob(cred_id_bytes),
        .public_key = zqlite.blob(&sec1),
    });

    log.info("Registered credential ({} bytes)", .{cred_id_bytes.len});

    try request.respond("{\"ok\":true}", .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleLoginChallenge(auth: *Auth, request: *std.http.Server.Request, io: Io) !void {
    var challenge: [32]u8 = undefined;
    io.random(&challenge);

    const now = Io.Timestamp.now(io, .real);

    {
        auth.mutex.lockUncancelable(io);
        defer auth.mutex.unlock(io);

        auth.evictExpiredChallenges(now);
        if (auth.pending_challenges.capacity == auth.pending_challenges.items.len) {
            _ = auth.pending_challenges.orderedRemove(0);
        }
        auth.pending_challenges.appendAssumeCapacity(.{ .challenge = challenge, .timestamp = now });
    }

    var challenge_b64_buf: [64]u8 = undefined;
    const challenge_b64 = base64url.Encoder.encode(&challenge_b64_buf, &challenge);

    var write_buf: [4096]u8 = undefined;
    var body_writer = try request.respondStreaming(&write_buf, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        },
    });

    try body_writer.writer.print(
        \\{{"challenge":"{s}","rpId":"{s}","userVerification":"preferred"}}
    , .{ challenge_b64, auth.config.rp_id });
    try body_writer.end();
}

pub fn handleLogin(auth: *Auth, request: *std.http.Server.Request, io: Io) !void {
    var read_buf: [4096]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    const body = readBody(request, &read_buf, &body_buf) orelse {
        try request.respond("Bad Request", .{ .status = .bad_request });
        return;
    };

    const parsed = std.json.parseFromSlice(LoginRequest, std.heap.smp_allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try request.respond("Invalid JSON", .{ .status = .bad_request });
        return;
    };
    defer parsed.deinit();
    const login = parsed.value;

    // Decode clientDataJSON
    var client_data_raw: [1024]u8 = undefined;
    const client_data_len = base64url.Decoder.calcSizeForSlice(login.clientDataJSON) catch {
        try request.respond("Invalid base64", .{ .status = .bad_request });
        return;
    };
    if (client_data_len > client_data_raw.len) {
        try request.respond("clientDataJSON too large", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&client_data_raw, login.clientDataJSON) catch {
        try request.respond("Invalid base64", .{ .status = .bad_request });
        return;
    };
    const client_data_json = client_data_raw[0..client_data_len];

    // Parse and verify clientDataJSON
    const client_data = std.json.parseFromSlice(ClientData, std.heap.smp_allocator, client_data_json, .{ .ignore_unknown_fields = true }) catch {
        try request.respond("Invalid clientDataJSON", .{ .status = .bad_request });
        return;
    };
    defer client_data.deinit();

    if (!std.mem.eql(u8, client_data.value.type, "webauthn.get")) {
        try request.respond("Wrong type", .{ .status = .bad_request });
        return;
    }
    if (!std.mem.eql(u8, client_data.value.origin, auth.config.origin)) {
        try request.respond("Wrong origin", .{ .status = .bad_request });
        return;
    }

    // Verify challenge
    var challenge_raw: [32]u8 = undefined;
    const chal_len = base64url.Decoder.calcSizeForSlice(client_data.value.challenge) catch {
        try request.respond("Invalid challenge base64", .{ .status = .bad_request });
        return;
    };
    if (chal_len != 32) {
        try request.respond("Invalid challenge length", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&challenge_raw, client_data.value.challenge) catch {
        try request.respond("Invalid challenge base64", .{ .status = .bad_request });
        return;
    };

    // Decode credential ID
    var cred_id_raw: [128]u8 = undefined;
    const cred_id_len = base64url.Decoder.calcSizeForSlice(login.id) catch {
        try request.respond("Invalid credential ID base64", .{ .status = .bad_request });
        return;
    };
    if (cred_id_len > 128) {
        try request.respond("Credential ID too long", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&cred_id_raw, login.id) catch {
        try request.respond("Invalid credential ID base64", .{ .status = .bad_request });
        return;
    };

    // Decode authenticatorData
    var auth_data_raw: [512]u8 = undefined;
    const auth_data_len = base64url.Decoder.calcSizeForSlice(login.authenticatorData) catch {
        try request.respond("Invalid authenticatorData base64", .{ .status = .bad_request });
        return;
    };
    if (auth_data_len > auth_data_raw.len) {
        try request.respond("authenticatorData too large", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&auth_data_raw, login.authenticatorData) catch {
        try request.respond("Invalid authenticatorData base64", .{ .status = .bad_request });
        return;
    };
    const auth_data = auth_data_raw[0..auth_data_len];

    // Decode signature
    var sig_raw: [256]u8 = undefined;
    const sig_len = base64url.Decoder.calcSizeForSlice(login.signature) catch {
        try request.respond("Invalid signature base64", .{ .status = .bad_request });
        return;
    };
    if (sig_len > sig_raw.len) {
        try request.respond("Signature too large", .{ .status = .bad_request });
        return;
    }
    base64url.Decoder.decode(&sig_raw, login.signature) catch {
        try request.respond("Invalid signature base64", .{ .status = .bad_request });
        return;
    };

    // Verify rpIdHash
    if (auth_data_len < 37) {
        try request.respond("authenticatorData too short", .{ .status = .bad_request });
        return;
    }
    var expected_rp_hash: [32]u8 = undefined;
    Sha256.hash(auth.config.rp_id, &expected_rp_hash, .{});
    if (!std.mem.eql(u8, auth_data[0..32], &expected_rp_hash)) {
        try request.respond("rpIdHash mismatch", .{ .status = .bad_request });
        return;
    }

    // Verify UP flag (bit 0) must be set for login
    if (auth_data[32] & 0x01 != 0x01) {
        try request.respond("Missing UP flag", .{ .status = .bad_request });
        return;
    }

    // Verify signature: signed_data = authenticatorData ++ sha256(clientDataJSON)
    var client_data_hash: [32]u8 = undefined;
    Sha256.hash(client_data_json, &client_data_hash, .{});
    var signed_data: [544]u8 = undefined; // 512 (max auth_data) + 32 (hash)
    @memcpy(signed_data[0..auth_data_len], auth_data);
    @memcpy(signed_data[auth_data_len .. auth_data_len + 32], &client_data_hash);

    const sig = EcdsaP256Sha256.Signature.fromDer(sig_raw[0..sig_len]) catch {
        try request.respond("Invalid signature format", .{ .status = .bad_request });
        return;
    };

    // DB ops outside lock
    const row = auth.qs.select_credential.run(@src(), auth.db.*, .{
        .cred_id = zqlite.blob(cred_id_raw[0..cred_id_len]),
    });

    if (row == null) {
        try request.respond("Unknown credential", .{ .status = .bad_request });
        return;
    }

    const cred_row = row.?;
    const cred_db_id = cred_row.get(.id);
    const sec1_blob = cred_row.textNoDupe(.public_key);

    if (sec1_blob.len != 65) {
        try request.respond("Corrupted credential", .{ .status = .internal_server_error });
        return;
    }

    const pub_key = EcdsaP256Sha256.PublicKey.fromSec1(sec1_blob[0..65]) catch {
        try request.respond("Corrupted credential key", .{ .status = .internal_server_error });
        return;
    };

    sig.verify(signed_data[0 .. auth_data_len + 32], pub_key) catch {
        try request.respond("Signature verification failed", .{ .status = .bad_request });
        return;
    };

    // Consume challenge under lock (after successful signature verification)
    {
        auth.mutex.lockUncancelable(io);
        defer auth.mutex.unlock(io);

        if (!auth.consumeChallenge(challenge_raw, Io.Timestamp.now(io, .real))) {
            try request.respond("Unknown challenge", .{ .status = .bad_request });
            return;
        }
    }

    // Generate session token and insert
    var token: [16]u8 = undefined;
    io.random(&token);

    auth.qs.insert_session.run(@src(), auth.db.*, .{
        .token = zqlite.blob(&token),
        .credential = cred_db_id,
    });

    const token_hex = std.fmt.bytesToHex(token, .lower);
    var cookie_buf: [128]u8 = undefined;
    const secure_suffix: []const u8 = if (auth.config.secure_cookie) "; Secure" else "";
    const cookie = std.fmt.bufPrint(&cookie_buf, "session={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000{s}", .{ token_hex, secure_suffix }) catch unreachable;

    log.info("Login successful, session created", .{});

    try request.respond("{\"ok\":true}", .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "set-cookie", .value = cookie },
        },
    });
}

pub fn handleLogout(auth: *Auth, request: *std.http.Server.Request, _: Io) !void {
    const token = parseSessionToken(request);
    if (token) |t| {
        auth.qs.delete_session.run(@src(), auth.db.*, .{
            .token = zqlite.blob(&t),
        });
    }

    try request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "location", .value = "/" },
            .{ .name = "set-cookie", .value = "session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0" },
        },
    });
}

pub fn getSession(auth: *const Auth, request: *std.http.Server.Request) ?i64 {
    if (auth.config.debug_bypass) return 1;

    const token = parseSessionToken(request) orelse return null;

    const row = auth.qs.select_session.run(@src(), auth.db.*, .{
        .token = zqlite.blob(&token),
    });

    if (row) |r| {
        return r.get(.credential);
    }
    return null;
}

fn isExpired(timestamp: Io.Timestamp, now: Io.Timestamp) bool {
    return timestamp.durationTo(now).nanoseconds > challenge_timeout.nanoseconds;
}

fn consumeChallenge(auth: *Auth, challenge: [32]u8, now: Io.Timestamp) bool {
    for (auth.pending_challenges.items, 0..) |pending, i| {
        if (std.mem.eql(u8, &pending.challenge, &challenge)) {
            _ = auth.pending_challenges.orderedRemove(i);
            return !isExpired(pending.timestamp, now);
        }
    }
    return false;
}

fn evictExpiredChallenges(auth: *Auth, now: Io.Timestamp) void {
    var i: usize = 0;
    while (i < auth.pending_challenges.items.len) {
        if (isExpired(auth.pending_challenges.items[i].timestamp, now)) {
            _ = auth.pending_challenges.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn parseSessionToken(request: *std.http.Server.Request) ?[16]u8 {
    const cookie_value = getSessionCookie(request) orelse return null;
    var token: [16]u8 = undefined;
    for (0..16) |i| {
        token[i] = std.fmt.parseInt(u8, cookie_value[i * 2 ..][0..2], 16) catch return null;
    }
    return token;
}

// JSON types for parsing

const RegisterRequest = struct {
    id: []const u8,
    clientDataJSON: []const u8,
    attestationObject: []const u8,
};

const LoginRequest = struct {
    id: []const u8,
    clientDataJSON: []const u8,
    authenticatorData: []const u8,
    signature: []const u8,
};

const ClientData = struct {
    type: []const u8,
    challenge: []const u8,
    origin: []const u8,
};

fn getSessionCookie(request: *std.http.Server.Request) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            // Find session=<32 hex chars>, ensuring it's a full cookie name
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, header.value, search_from, "session=")) |pos| {
                if (pos == 0 or std.mem.eql(u8, header.value[pos - 2 .. pos], "; ")) {
                    const start = pos + "session=".len;
                    if (header.value.len >= start + 32) {
                        return header.value[start .. start + 32];
                    }
                }
                search_from = pos + 1;
            }
        }
    }
    return null;
}

fn readBody(request: *std.http.Server.Request, read_buf: []u8, body_buf: []u8) ?[]const u8 {
    const len = request.head.content_length orelse return null;
    if (len == 0 or len > body_buf.len) return null;
    const n: usize = @intCast(len);
    var reader = request.readerExpectNone(read_buf);
    reader.readSliceAll(body_buf[0..n]) catch return null;
    return body_buf[0..n];
}

fn parseAttestationObject(data: []const u8, auth_data_out: *[]const u8) bool {
    var iter: []const u8 = data;
    const n_items = cbor.decodeMapHeader(&iter) catch return false;
    for (0..n_items) |_| {
        var key: []const u8 = undefined;
        if (!(cbor.matchString(&iter, &key) catch return false)) return false;
        if (std.mem.eql(u8, key, "authData")) {
            var val: []const u8 = undefined;
            if (!(cbor.matchString(&iter, &val) catch return false)) return false;
            auth_data_out.* = val;
            return true;
        } else {
            cbor.skipValue(&iter) catch return false;
        }
    }
    return false;
}

const CoseKey = enum(i64) {
    kty = 1,
    alg = 3,
    crv = -1,
    x = -2,
    y = -3,
    _,
};

const CoseKty = enum(i64) {
    ec2 = 2,
    _,
};

const CoseAlg = enum(i64) {
    es256 = -7,
    _,
};

const CoseCrv = enum(i64) {
    p256 = 1,
    _,
};

fn parseCoseKey(data: []const u8) !EcdsaP256Sha256.PublicKey {
    var iter: []const u8 = data;
    const n_items = cbor.decodeMapHeader(&iter) catch return error.InvalidCoseKey;

    var x: ?[]const u8 = null;
    var y: ?[]const u8 = null;
    var kty: ?CoseKty = null;
    var alg: ?CoseAlg = null;
    var crv: ?CoseCrv = null;

    for (0..n_items) |_| {
        var key_int: i64 = 0;
        if (cbor.matchInt(i64, &iter, &key_int) catch return error.InvalidCoseKey) {
            const key: CoseKey = @enumFromInt(key_int);
            switch (key) {
                .kty => kty = readIntEnum(CoseKty, &iter) orelse return error.InvalidCoseKey,
                .alg => alg = readIntEnum(CoseAlg, &iter) orelse return error.InvalidCoseKey,
                .crv => crv = readIntEnum(CoseCrv, &iter) orelse return error.InvalidCoseKey,
                .x => x = readBytes(&iter) orelse return error.InvalidCoseKey,
                .y => y = readBytes(&iter) orelse return error.InvalidCoseKey,
                _ => cbor.skipValue(&iter) catch return error.InvalidCoseKey,
            }
        } else {
            cbor.skipValue(&iter) catch return error.InvalidCoseKey;
        }
    }

    if ((kty orelse return error.InvalidCoseKey) != .ec2) return error.InvalidCoseKey;
    if ((alg orelse return error.InvalidCoseKey) != .es256) return error.InvalidCoseKey;
    if ((crv orelse return error.InvalidCoseKey) != .p256) return error.InvalidCoseKey;

    const x_val = x orelse return error.InvalidCoseKey;
    const y_val = y orelse return error.InvalidCoseKey;
    if (x_val.len != 32 or y_val.len != 32) return error.InvalidCoseKey;

    const sec1 = [1]u8{0x04} ++ x_val[0..32].* ++ y_val[0..32].*;
    return EcdsaP256Sha256.PublicKey.fromSec1(&sec1) catch return error.InvalidCoseKey;
}

fn readIntEnum(comptime E: type, iter: *[]const u8) ?E {
    var val: i64 = 0;
    if (cbor.matchInt(i64, iter, &val) catch return null) {
        return @enumFromInt(val);
    }
    return null;
}

fn readBytes(iter: *[]const u8) ?[]const u8 {
    var val: []const u8 = undefined;
    if (cbor.matchString(iter, &val) catch return null) return val;
    return null;
}
