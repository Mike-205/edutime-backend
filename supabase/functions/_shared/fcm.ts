// Thin wrapper around FCM's HTTP v1 API
// (https://firebase.google.com/docs/cloud-messaging/migrate-v1). v1
// authenticates with a Google service-account OAuth token, not the legacy
// static server key — TODO 3.1 ruled the legacy key out explicitly — so this
// module signs a JWT with the service account's private key, exchanges it
// for a short-lived access token at Google's token endpoint, and caches that
// token in module scope for its ~1h life. `edge_runtime.policy =
// "per_worker"` (config.toml) keeps this module warm between invocations
// locally; a cold worker just re-mints one, same cost as every other run.
//
// FCM_SERVICE_ACCOUNT holds the whole service-account JSON, base64-encoded —
// the file's own `private_key` field is one string containing literal `\n`
// escapes, and round-tripping that through config.toml's TOML string / the
// env var untouched risks mangling them; base64 sidesteps that entirely.
// Unset locally, sendPush logs and returns instead of calling out — the same
// swap-for-free behaviour as _shared/axene.ts.
interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

interface CachedToken {
  accessToken: string;
  expiresAt: number; // epoch ms
}

let cached: CachedToken | null = null;

function loadServiceAccount(): ServiceAccount | null {
  const b64 = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!b64) return null;
  return JSON.parse(atob(b64)) as ServiceAccount;
}

function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string"
    ? new TextEncoder().encode(input)
    : new Uint8Array(input);
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function mintAccessToken(sa: ServiceAccount): Promise<CachedToken> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  const key = await importPrivateKey(sa.private_key);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!res.ok) {
    throw new Error(`FCM token exchange failed (${res.status}): ${await res.text()}`);
  }

  const data = (await res.json()) as { access_token: string; expires_in: number };
  return {
    accessToken: data.access_token,
    // Shaved by a minute so a token already in flight never expires mid-request.
    expiresAt: Date.now() + (data.expires_in - 60) * 1000,
  };
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.expiresAt > Date.now()) return cached.accessToken;
  cached = await mintAccessToken(sa);
  return cached.accessToken;
}

export interface PushMessage {
  token: string;
  title: string;
  body: string;
  type: string;
  eventId: string | null;
}

export type PushResult = "sent" | "unregistered" | "error" | "not_configured";

export async function sendPush(msg: PushMessage): Promise<PushResult> {
  const sa = loadServiceAccount();
  if (!sa) {
    console.log(`[fcm:noop] would push to ${msg.token} - "${msg.title}"`);
    return "not_configured";
  }

  const accessToken = await getAccessToken(sa);

  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: msg.token,
          notification: { title: msg.title, body: msg.body },
          data: { type: msg.type, event_id: msg.eventId ?? "" },
        },
      }),
    },
  );

  if (res.ok) {
    return "sent";
  }

  const body = await res.text();
  console.error(`[fcm] send failed (${res.status}) for ${msg.token}: ${body}`);

  // UNREGISTERED is FCM's specific signal that this token is dead (app
  // uninstalled, token rotated, etc.) — the one case TODO 3.1 asks this to
  // clean up. Everything else (bad payload, quota, transient 5xx, a merely
  // malformed token which is INVALID_ARGUMENT, not UNREGISTERED) is logged
  // and left alone: no retry/backoff system, per 3.1's explicit scope.
  //
  // v1's dead-token error puts UNREGISTERED in error.details[].errorCode,
  // NOT in the top-level error.status (that's NOT_FOUND) — parsed rather
  // than substring-matched so a shape this doesn't expect fails safe as
  // "error", never as a false-positive delete.
  try {
    const parsed = JSON.parse(body) as {
      error?: { status?: string; details?: Array<{ errorCode?: string }> };
    };
    const isUnregistered = parsed.error?.status === "UNREGISTERED" ||
      (parsed.error?.details ?? []).some((d) => d.errorCode === "UNREGISTERED");
    return isUnregistered ? "unregistered" : "error";
  } catch {
    return "error";
  }
}
