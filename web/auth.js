const b64opts = { alphabet: "base64url", omitPadding: true };
const b64encode = (buf) => new Uint8Array(buf).toBase64(b64opts);
const b64decode = (s) => Uint8Array.fromBase64(s, b64opts);

async function register() {
  try {
    const res = await fetch('/auth/register-challenge');
    const opts = await res.json();
    opts.challenge = b64decode(opts.challenge);
    opts.user.id = b64decode(opts.user.id);

    const cred = await navigator.credentials.create({ publicKey: opts });
    if (!cred) return;

    const body = JSON.stringify({
      id: b64encode(cred.rawId),
      clientDataJSON: b64encode(cred.response.clientDataJSON),
      attestationObject: b64encode(cred.response.attestationObject),
    });

    const r = await fetch('/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });

    if (r.ok) document.getElementById('btn-register').remove();
    else alert('Registration failed: ' + await r.text());
  } catch (e) {
    if (e.name !== 'NotAllowedError') alert('Error: ' + e.message);
  }
}

async function login() {
  try {
    const res = await fetch('/auth/login-challenge');
    const opts = await res.json();
    opts.challenge = b64decode(opts.challenge);

    const cred = await navigator.credentials.get({ publicKey: opts });
    if (!cred) return;

    const body = JSON.stringify({
      id: b64encode(cred.rawId),
      clientDataJSON: b64encode(cred.response.clientDataJSON),
      authenticatorData: b64encode(cred.response.authenticatorData),
      signature: b64encode(cred.response.signature),
    });

    const r = await fetch('/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });

    if (r.ok) location.reload();
    else alert('Login failed: ' + await r.text());
  } catch (e) {
    if (e.name !== 'NotAllowedError') alert('Error: ' + e.message);
  }
}

document.getElementById('btn-register')?.addEventListener('click', register);
document.getElementById('btn-login')?.addEventListener('click', login);
document.getElementById('btn-logout')?.addEventListener('click', async () => {
  await fetch('/auth/logout', { method: 'POST' });
  location.reload();
});
