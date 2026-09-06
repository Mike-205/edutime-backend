// R.5 — the unauthenticated "forgot password" entry point.
//
// A registration number in, one generic response out, always — whether the
// number exists, whether that account is on the OAuth branch, whether a
// recovery email is on file, or whether the account already requested a
// reset within the cooldown window. All of that is resolved by
// `request_password_recovery`, called here with the service-role key, which
// is the only thing allowed to call it (0031 §5). That SQL function decides
// `should_send`; this function's only two jobs when it's true are minting
// the GoTrue recovery link and handing it to Axene — see TECHNICAL_DISCOVERY
// §11 for why the link has to be minted against the account's *synthetic*
// `@auth.internal` address rather than `recovery_email` itself.
import { corsHeaders } from "../_shared/cors.ts";
import { sendEmail } from "../_shared/axene.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Identical regardless of what actually happened server-side — the whole
// point of the generic-response discipline (TODO §0.5 step 2, carried into
// R.5 by 0031 §4's header comment).
const GENERIC_RESPONSE = {
  message:
    "If that registration number has a verified recovery email on file, a reset link has been sent.",
};

interface LookupResult {
  should_send: boolean;
  auth_email?: string;
  recovery_email?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let regNumber: string;
  try {
    const body = await req.json();
    if (typeof body.reg_number !== "string" || body.reg_number.trim() === "") {
      throw new Error("reg_number is required");
    }
    regNumber = body.reg_number;
  } catch {
    return new Response(
      JSON.stringify({ error: "Expected a JSON body with reg_number" }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  const lookupRes = await fetch(
    `${SUPABASE_URL}/rest/v1/rpc/request_password_recovery`,
    {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_reg_number: regNumber }),
    },
  );

  if (!lookupRes.ok) {
    console.error("request_password_recovery failed:", await lookupRes.text());
    return new Response(JSON.stringify(GENERIC_RESPONSE), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const lookup = (await lookupRes.json()) as LookupResult;

  if (lookup.should_send && lookup.auth_email && lookup.recovery_email) {
    try {
      const linkRes = await fetch(
        `${SUPABASE_URL}/auth/v1/admin/generate_link`,
        {
          method: "POST",
          headers: {
            apikey: SERVICE_ROLE_KEY,
            Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ type: "recovery", email: lookup.auth_email }),
        },
      );

      if (!linkRes.ok) {
        throw new Error(`generate_link failed (${linkRes.status}): ${await linkRes.text()}`);
      }

      const { action_link } = (await linkRes.json()) as { action_link: string };

      await sendEmail({
        to: lookup.recovery_email,
        subject: "Reset your Edutime password",
        html: `<p>Someone requested a password reset for your Edutime account.</p>` +
          `<p><a href="${action_link}">Reset your password</a></p>` +
          `<p>If this wasn't you, you can ignore this email.</p>`,
        text: `Someone requested a password reset for your Edutime account.\n\n` +
          `Reset your password: ${action_link}\n\n` +
          `If this wasn't you, you can ignore this email.`,
      });
    } catch (err) {
      // Logged, never surfaced — the response is generic either way, and a
      // delivery failure here must not become a signal that the account
      // exists.
      console.error("recovery-request delivery failed:", err);
    }
  }

  return new Response(JSON.stringify(GENERIC_RESPONSE), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
