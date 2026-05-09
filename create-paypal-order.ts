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

    const body       = await req.json();
    const { user_id, package_id, amount, coins } = body;

    if (!user_id || !package_id || !amount || !coins) {
      return new Response(JSON.stringify({ error: "Missing fields" }), { status: 400 });
    }

    const token = await getPayPalToken();

    // Create a PayPal order (one-time payment)
    const res = await fetch(`https://${PAYPAL_MODE}/v2/checkout/orders`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type":  "application/json",
      },
      body: JSON.stringify({
        intent: "CAPTURE",
        purchase_units: [{
          amount: {
            currency_code: "USD",
            value:         amount,
          },
          description:  `EZCompleteUI — ${coins} EZ Coins`,
          custom_id:    `${user_id}|${package_id}|${coins}`, // parsed by capture function
        }],
        application_context: {
          return_url:  "https://www.paypal.com",
          cancel_url:  "https://www.paypal.com",
          user_action: "PAY_NOW",
        },
      }),
    });

    const data = await res.json();
    console.log(`[create-paypal-order] order_id=${data.id} user=${user_id} package=${package_id} coins=${coins}`);

    const approveLink = data.links?.find((l: { rel: string; href: string }) => l.rel === "approve")?.href;
    if (!approveLink) {
      return new Response(JSON.stringify({ error: "No approve link", detail: data }), { status: 500 });
    }

    return new Response(JSON.stringify({
      order_id:    data.id,
      approve_url: approveLink,
    }), {
      status:  200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (e) {
    console.error("[create-paypal-order]", e);
    return new Response(JSON.stringify({ error: "Server error" }), { status: 500 });
  }
});
