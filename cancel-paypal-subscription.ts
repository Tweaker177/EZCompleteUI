import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYPAL_MODE = Deno.env.get("PAYPAL_MODE") === "live"
  ? "api-m.paypal.com"
  : "api-m.sandbox.paypal.com";

async function getPayPalToken(): Promise<string> {
  const clientId = Deno.env.get("PAYPAL_CLIENT_ID")!;
  const secret   = Deno.env.get("PAYPAL_SECRET")!;
  const res = await fetch(`https://${PAYPAL_MODE}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      "Authorization": `Basic ${btoa(`${clientId}:${secret}`)}`,
      "Content-Type":  "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  const data = await res.json();
  return data.access_token;
}

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "No auth" }), { status: 401 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Invalid token" }), { status: 401 });
    }

    // Fetch the user's current active subscription ID
    const { data: sub } = await supabase
      .from("subscriptions")
      .select("provider_subscription_id")
      .eq("user_id", user.id)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!sub?.provider_subscription_id) {
      // No active subscription — nothing to cancel
      return new Response(JSON.stringify({ success: true, message: "No active subscription found" }), {
        status:  200,
        headers: { "Content-Type": "application/json" },
      });
    }

    const subscriptionId = sub.provider_subscription_id;
    const token          = await getPayPalToken();

    // Cancel with PayPal
    const cancelRes = await fetch(
      `https://${PAYPAL_MODE}/v1/billing/subscriptions/${subscriptionId}/cancel`,
      {
        method:  "POST",
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type":  "application/json",
        },
        body: JSON.stringify({ reason: "User upgraded to a different plan" }),
      }
    );

    console.log(`[cancel-paypal-subscription] sub=${subscriptionId} status=${cancelRes.status}`);

    // Mark as cancelled in DB regardless of PayPal response
    // (PayPal returns 204 on success, may return 422 if already cancelled)
    await supabase
      .from("subscriptions")
      .update({ status: "cancelled", updated_at: new Date().toISOString() })
      .eq("user_id", user.id);

    return new Response(JSON.stringify({ success: true }), {
      status:  200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (e) {
    console.error("[cancel-paypal-subscription]", e);
    return new Response(JSON.stringify({ error: "Server error" }), { status: 500 });
  }
});
