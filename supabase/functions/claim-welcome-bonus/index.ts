// Atomically grants the one-time new-account coins and free spins.
//
// This intentionally runs after authentication rather than in an auth.users
// trigger, because this Edge request has the proxy-provided client IP needed
// for the server-side anti-abuse rule.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function headers() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type, apikey",
    "Content-Type": "application/json",
  };
}

function json(body: object, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: headers() });
}

function requestIPAddress(req: Request): string | null {
  const value = req.headers.get("cf-connecting-ip")
    ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim()
    ?? req.headers.get("x-real-ip");
  if (!value || value.toLowerCase() === "unknown") return null;
  return value.slice(0, 64);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: headers() });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "Unauthorized" }, 401);

  const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: auth, error: authError } = await service.auth.getUser(authHeader.slice(7));
  if (authError || !auth.user) return json({ error: "Unauthorized" }, 401);

  const ipAddress = requestIPAddress(req);
  if (!ipAddress) return json({ granted: false, reason: "ip_unavailable" }, 200);

  const { data, error } = await service.rpc("claim_welcome_bonus", {
    p_user_id: auth.user.id,
    p_ip_address: ipAddress,
  }).maybeSingle();
  if (error) {
    console.error("[claim-welcome-bonus] RPC failed:", error.message);
    return json({ error: "Could not claim welcome bonus" }, 500);
  }

  return json(data ?? { granted: false, reason: "not_eligible" });
});
