# WebAuthn Authentication Flow

*2026-03-16T12:17:35Z by Showboat 0.6.1*
<!-- showboat-id: 8f8456b0-fe0c-4e25-b8a1-80f1b652b53e -->

Passwordless authentication using WebAuthn/FIDO2 with ECDSA P-256. Challenges are stored in a bounded in-memory pool (max 64, 5-minute expiry). Sessions are cookie-based, backed by SQLite.

## 1. Registration

The client fetches a challenge, then the browser calls `navigator.credentials.create()` to generate a key pair. The server stores the public key.

```bash
curl -s http://localhost:8080/auth/register-challenge | python3 -m json.tool
```

```output
{
    "challenge": "p8zuUTxCNr2TSknWiOjd6YNbgrFtX0UIkv14uqrLPLo",
    "rp": {
        "name": "ZigWeb Demo"
    },
    "pubKeyCredParams": [
        {
            "type": "public-key",
            "alg": -7
        }
    ],
    "authenticatorSelection": {
        "userVerification": "preferred",
        "residentKey": "preferred"
    },
    "user": {
        "id": "p8zuUTxCNr2TSknWiOjd6YNbgrFtX0UIkv14uqrLPLo",
        "name": "user",
        "displayName": "User"
    }
}
```

The server verifies the attestation object (`/auth/register`): checks origin, consumes the challenge, verifies the RP ID hash, and extracts the COSE public key from the CBOR authData.

```bash
sed -n '192,259p' src/auth.zig
```

```output
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
```

## 2. Login

The client fetches a login challenge, then the browser calls `navigator.credentials.get()` to sign it. The server verifies the signature, then creates a session.

```bash
curl -s http://localhost:8080/auth/login-challenge | python3 -m json.tool
```

```output
{
    "challenge": "aEphGl61ZUapeCMmR4yAEkswMxMqvtm2GNNHuXLTlVE",
    "rpId": "localhost",
    "userVerification": "preferred"
}
```

The signature is verified *before* consuming the challenge, so failed attempts do not waste valid challenges.

```bash
sed -n '422,496p' src/auth.zig
```

```output
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
```

## 3. Logout

Deletes the session from the database and clears the cookie.

```bash
curl -sv http://localhost:8080/auth/logout 2>&1 | grep -E "^< (HTTP|location|set-cookie)"
```

```output
< HTTP/1.1 303 See Other
< location: /
< set-cookie: session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0
```
