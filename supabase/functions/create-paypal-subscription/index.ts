import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const PAYPAL_MODE = Deno.env.get("PAYPAL_MODE") === "live"
  ? "api-m.paypal.com"
  : "api-m.sandbox.paypal.com";

async function getPayPalToken(): Promise<string> {
  const clientId = Deno.env.get("PAYPAL_CLIENT_ID")!;
  const secret = Deno.env.get("PAYPAL_SECRET")!;
  const res = await fetch(`https://${PAYPAL_MODE}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      "Authorization": `Basic ${btoa(`${clientId}:${secret}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  const data = await res.json();
  return data.access_token;
}

serve(async (req) => {
  try {
    const { plan_id, user_id } = await req.json();

    if (!plan_id || !user_id) {
      return new Response(JSON.stringify({ error: "Missing plan_id or user_id" }), { status: 400 });
    }

    const token = await getPayPalToken();

    const res = await fetch(`https://${PAYPAL_MODE}/v1/billing/subscriptions`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        plan_id: plan_id,
        custom_id: user_id,
        application_context: {
          return_url: "https://www.paypal.com",
          cancel_url: "https://www.paypal.com",
          user_action: "SUBSCRIBE_NOW",
        },
      }),
    });

    const data = await res.json();

    const approveLink = data.links?.find((l: any) => l.rel === "approve")?.href;

    if (!approveLink) {
      return new Response(JSON.stringify({ error: "No approve link", detail: data }), { status: 500 });
    }

    return new Response(JSON.stringify({
      subscription_id: data.id,
      approve_url: approveLink,
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: "Server error" }), { status: 500 });
  }
});
