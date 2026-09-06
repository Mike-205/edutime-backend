// Mobile-only for MVP (TODO.md "Explicitly not doing"), so this exists only
// for local testing with curl/Postman and the odd web-based debugging tool —
// not because a browser client is expected in production.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};
