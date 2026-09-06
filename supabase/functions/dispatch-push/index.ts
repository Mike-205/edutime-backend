// 3.1 — the FCM half of push delivery. Invoked by pg_cron every minute
// (0034's invoke_push_dispatch(), via net.http_post) with the service-role
// key as its bearer token — nothing else is meant to call this. It claims a
// batch of undelivered notifications from claim_pending_pushes() (0034),
// sends each to FCM via _shared/fcm.ts, and deletes any device_tokens row
// FCM reports as UNREGISTERED. See 0034's header for why this is a poll
// rather than an on-insert webhook, and TODO §3.1 for why cleanup stops at
// exactly that one error.
import { sendPush } from "../_shared/fcm.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface ClaimedPush {
  notification_id: string;
  token: string;
  platform: "ios" | "android";
  title: string;
  message: string;
  type: string;
  event_id: string | null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const claimRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/claim_pending_pushes`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });

  if (!claimRes.ok) {
    console.error("claim_pending_pushes failed:", await claimRes.text());
    return new Response(JSON.stringify({ error: "claim failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const claimed = (await claimRes.json()) as ClaimedPush[];
  let sent = 0;
  let unregistered = 0;
  let errors = 0;

  for (const push of claimed) {
    const result = await sendPush({
      token: push.token,
      title: push.title,
      body: push.message,
      type: push.type,
      eventId: push.event_id,
    });

    if (result === "sent") {
      sent++;
    } else if (result === "error") {
      errors++;
    } else if (result === "unregistered") {
      unregistered++;
      const delRes = await fetch(
        `${SUPABASE_URL}/rest/v1/device_tokens?token=eq.${encodeURIComponent(push.token)}`,
        {
          method: "DELETE",
          headers: {
            apikey: SERVICE_ROLE_KEY,
            Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          },
        },
      );
      if (!delRes.ok) {
        console.error(`failed to delete stale token ${push.token}:`, await delRes.text());
      }
    }
    // "not_configured" (FCM_SERVICE_ACCOUNT unset): already logged in
    // fcm.ts. The notification stays stamped pushed_at regardless — claim_
    // pending_pushes() already did that — matching axene.ts's local-noop
    // discipline rather than leaving it pending forever.
  }

  return new Response(
    JSON.stringify({ claimed: claimed.length, sent, unregistered, errors }),
    { headers: { "Content-Type": "application/json" } },
  );
});
