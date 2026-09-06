// Thin wrapper around Axene Mailer's REST API (https://axene.io/docs/mailer).
//
// Deno's `fetch` is a web-standard global, so this needs no SDK dependency —
// one function, one endpoint. AXENE_API_KEY is read from the environment
// (wired through by [edge_runtime.secrets] in config.toml locally, or
// `supabase secrets set` when hosted) rather than passed in, so every caller
// gets the same swap-for-free behaviour: unset locally, it logs instead of
// sending, so nothing breaks `supabase functions serve` with no key
// configured.

interface SendEmailArgs {
  to: string;
  toName?: string;
  subject: string;
  html: string;
  text: string;
}

interface AxeneSendResponse {
  id: string;
  status: string;
  message_id: string;
  rejection_reason: string | null;
}

export async function sendEmail(args: SendEmailArgs): Promise<void> {
  const apiKey = Deno.env.get("AXENE_API_KEY");
  const senderEmail = Deno.env.get("AXENE_SENDER_EMAIL");
  const senderName = Deno.env.get("AXENE_SENDER_NAME") ?? "Edutime";

  if (!apiKey || !senderEmail) {
    console.log(
      `[axene:noop] would send to ${args.to} — subject: "${args.subject}"\n${args.text}`,
    );
    return;
  }

  // The trailing slash is load-bearing: without it Axene's API answers with
  // a 401 `not_authenticated` regardless of how good the key is — reproduced
  // with two separately-generated keys before the fix was found empirically
  // by comparing against a request that actually worked. `/v1/emails/validate`
  // (no such collision, it's a sub-path, not the collection root) never
  // needed one.
  const res = await fetch("https://mail.axene.io/v1/emails/", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from_: { email: senderEmail, name: senderName },
      to: [{ email: args.to, name: args.toName }],
      subject: args.subject,
      html: args.html,
      text: args.text,
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Axene send failed (${res.status}): ${body}`);
  }

  const data = (await res.json()) as AxeneSendResponse;
  console.log(`[axene] ${data.id} ${data.status} to ${args.to} (${data.message_id})`);
}
