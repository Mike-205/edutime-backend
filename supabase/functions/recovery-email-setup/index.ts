// R.5 — authenticated. Two steps, one endpoint, distinguished by `step`:
//
//   { step: "request", email }  -> stores the address, emails a 6-digit code
//   { step: "verify",  code }   -> confirms the code
//
// Kept as one function because both steps need the identical auth handling
// and nothing else — splitting them would duplicate that, not remove it.
//
// Calls 0031's set_recovery_email / verify_recovery_email THROUGH PostgREST
// with the CALLER'S OWN JWT, not the service-role key. That matters: both
// functions check `p_acting_user = auth.uid()` internally, and auth.uid()
// only resolves to the right person when PostgREST forwards that person's
// own token. Using the service-role key here would make every call look
// like it came from nobody (auth.uid() null), and the self-check would
// refuse it.
import { corsHeaders } from "../_shared/cors.ts";
import { sendEmail } from "../_shared/axene.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

async function currentUser(authHeader: string) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: authHeader },
  });
  if (!res.ok) return null;
  return (await res.json()) as { id: string };
}

async function callRpc(
  fn: string,
  authHeader: string,
  args: Record<string, unknown>,
) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: ANON_KEY,
      Authorization: authHeader,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const body = await res.json();
  if (!res.ok) {
    // PostgREST surfaces a raised `raise exception` message as body.message.
    throw new Error(typeof body.message === "string" ? body.message : "Request failed");
  }
  return body;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  const user = await currentUser(authHeader);
  if (!user) {
    return new Response(JSON.stringify({ error: "Not signed in" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  const body = await req.json().catch(() => ({}));

  try {
    if (body.step === "request") {
      if (typeof body.email !== "string" || body.email.trim() === "") {
        return new Response(JSON.stringify({ error: "email is required" }), {
          status: 400,
          headers: jsonHeaders,
        });
      }

      const otp = await callRpc("set_recovery_email", authHeader, {
        p_email: body.email,
        p_acting_user: user.id,
      });

      await sendEmail({
        to: body.email,
        subject: "Confirm your Edutime recovery email",
        html: `<p>Your verification code is:</p><p style="font-size:24px"><b>${otp}</b></p>` +
          `<p>It expires in 15 minutes.</p>`,
        text: `Your verification code is: ${otp}\nIt expires in 15 minutes.`,
      });

      return new Response(JSON.stringify({ message: "Verification code sent" }), {
        status: 200,
        headers: jsonHeaders,
      });
    }

    if (body.step === "verify") {
      if (typeof body.code !== "string" || body.code.trim() === "") {
        return new Response(JSON.stringify({ error: "code is required" }), {
          status: 400,
          headers: jsonHeaders,
        });
      }

      const verified = await callRpc("verify_recovery_email", authHeader, {
        p_code: body.code,
        p_acting_user: user.id,
      });

      return new Response(JSON.stringify({ verified }), {
        status: 200,
        headers: jsonHeaders,
      });
    }

    return new Response(JSON.stringify({ error: 'step must be "request" or "verify"' }), {
      status: 400,
      headers: jsonHeaders,
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 400,
      headers: jsonHeaders,
    });
  }
});
