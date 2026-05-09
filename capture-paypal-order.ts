import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// This function is called by the PayPal webhook when an order is approved
// (CHECKOUT.ORDER.APPROVED event) OR can be called directly by the iOS app
// after the user returns from PayPal checkout.
//
// It captures the payment and credits coins to the user's balance.

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
    const body     = await req.json();
    const orderId  = body.order_id ?? body.resource?.id;

    if (!orderId) {
      return new Response(JSON.stringify({ error: "Missing order_id" }), { status: 400 });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = await getPayPalToken();

    // Capture the order
    const captureRes = await fetch(
      `https://${PAYPAL_MODE}/v2/checkout/orders/${orderId}/capture`,
      {
        method:  "POST",
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type":  "application/json",
        },
      }
    );

    const captureData = await captureRes.json();
    console.log(`[capture-paypal-order] order=${orderId} status=${captureData.status}`);

    if (captureData.status !== "COMPLETED") {
      return new Response(JSON.stringify({
        error:  "Payment not completed",
        status: captureData.status,
      }), { status: 402 });
    }

    // Parse custom_id: "userId|packageId|coins"
    const customId = captureData.purchase_units?.[0]?.custom_id ?? "";
    const parts    = customId.split("|");
    if (parts.length < 3) {
      return new Response(JSON.stringify({ error: "Invalid custom_id" }), { status: 400 });
    }

    const userId     = parts[0];
    const packageId  = parts[1];
    const coinsToAdd = parseInt(parts[2], 10);

    if (!userId || isNaN(coinsToAdd)) {
      return new Response(JSON.stringify({ error: "Could not parse user/coins" }), { status: 400 });
    }

    // Fetch current balance
    const { data: sub } = await supabase
      .from("subscriptions")
      .select("coins_balance")
      .eq("user_id", userId)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const currentBalance = sub?.coins_balance ?? 0;
    const newBalance     = currentBalance + coinsToAdd;

    // Credit coins
    await supabase
      .from("subscriptions")
      .update({ coins_balance: newBalance, updated_at: new Date().toISOString() })
      .eq("user_id", userId);

    // Log transaction
    await supabase.from("coin_transactions").insert({
      user_id:       userId,
      amount:        coinsToAdd,
      direction:     "credit",
      feature:       "topup",
      description:   `Top-up: ${packageId} (+${coinsToAdd} coins)`,
      balance_after: newBalance,
    });

    console.log(`[capture-paypal-order] Credited ${coinsToAdd} coins to ${userId}, balance now ${newBalance}`);

    return new Response(JSON.stringify({
      success:     true,
      coins_added: coinsToAdd,
      balance:     newBalance,
    }), {
      status:  200,
      headers: { "Content-Type": "application/json" },
    });

  } catch (e) {
    console.error("[capture-paypal-order]", e);
    return new Response(JSON.stringify({ error: "Server error" }), { status: 500 });
  }
});
