import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const PAYPAL_MODE = Deno.env.get("PAYPAL_MODE") === "live"
  ? "api-m.paypal.com"
  : "api-m.sandbox.paypal.com";

const COINS_PER_TIER: Record<string, number> = {
  basic: 400,
  pro:   1000,
  ultra: 2500,
};

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

async function verifySubscription(subscriptionId: string, token: string) {
  const res = await fetch(
    `https://${PAYPAL_MODE}/v1/billing/subscriptions/${subscriptionId}`,
    { headers: { "Authorization": `Bearer ${token}` } }
  );
  return res.json();
}

function tierFromPlanId(planId: string): string {
  const map: Record<string, string> = {
    [Deno.env.get("PAYPAL_PLAN_BASIC") ?? ""]: "basic",
    [Deno.env.get("PAYPAL_PLAN_PRO")   ?? ""]: "pro",
    [Deno.env.get("PAYPAL_PLAN_ULTRA") ?? ""]: "ultra",
  };
  return map[planId] ?? "basic";
}

serve(async (req) => {
  try {
    const body      = await req.json();
    const eventType = body.event_type;
    const resource  = body.resource;

    console.log(`[paypal-webhook] Event: ${eventType}`);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token          = await getPayPalToken();
    const subscriptionId = resource.id ?? resource.billing_agreement_id;
    const subData        = await verifySubscription(subscriptionId, token);

    console.log(`[paypal-webhook] subscription_id=${subscriptionId} custom_id=${subData.custom_id} plan_id=${subData.plan_id} status=${subData.status}`);

    const userId = subData.custom_id;
    if (!userId) {
      console.error("[paypal-webhook] No user_id in custom_id — cannot credit coins");
      return new Response("No user_id in custom_id", { status: 400 });
    }

    const tier          = tierFromPlanId(subData.plan_id);
    const coinsToCredit = COINS_PER_TIER[tier] ?? 400;

    if (
      eventType === "BILLING.SUBSCRIPTION.ACTIVATED" ||
      eventType === "BILLING.SUBSCRIPTION.RENEWED"   ||
      eventType === "BILLING.SUBSCRIPTION.RE-ACTIVATED"
    ) {
      // Upsert on user_id so repeat subscriptions update the existing row
      // instead of creating duplicates. Duplicates break .single() queries
      // in check-entitlement and cause "no account found" errors in the app.
      const { error: upsertError } = await supabase
        .from("subscriptions")
        .upsert({
          user_id:                   userId,
          provider:                  "paypal",
          provider_subscription_id:  subData.id,
          provider_customer_id:      subData.subscriber?.payer_id,
          paypal_plan_id:            subData.plan_id,
          tier:                      tier,
          status:                    "active",
          coins_included:            coinsToCredit,
          coins_balance:             coinsToCredit,
          current_period_start:      subData.billing_info?.last_payment?.time,
          current_period_end:        subData.billing_info?.next_billing_time,
          updated_at:                new Date().toISOString(),
        }, { onConflict: "user_id" });  // ← was "provider_subscription_id"

      if (upsertError) {
        console.error("[paypal-webhook] Upsert error:", upsertError.message);
        return new Response("DB error", { status: 500 });
      }

      const { error: txError } = await supabase
        .from("coin_transactions")
        .insert({
          user_id:       userId,
          amount:        coinsToCredit,
          direction:     "credit",
          feature:       "subscription_renewal",
          description:   `${tier} plan — ${eventType}`,
          balance_after: coinsToCredit,
        });

      if (txError) {
        console.error("[paypal-webhook] coin_transactions insert error:", txError.message);
      }

      console.log(`[paypal-webhook] Credited ${coinsToCredit} coins to user ${userId} (${tier})`);

    } else if (
      eventType === "BILLING.SUBSCRIPTION.CANCELLED" ||
      eventType === "BILLING.SUBSCRIPTION.SUSPENDED" ||
      eventType === "BILLING.SUBSCRIPTION.EXPIRED"
    ) {
      const newStatus = eventType.includes("CANCELLED") ? "cancelled"
                      : eventType.includes("SUSPENDED") ? "suspended"
                      : "expired";

      await supabase
        .from("subscriptions")
        .update({
          status:     newStatus,
          updated_at: new Date().toISOString(),
        })
        .eq("user_id", userId);

      console.log(`[paypal-webhook] Set status=${newStatus} for user ${userId}`);

    } else {
      console.log(`[paypal-webhook] Unhandled event type: ${eventType} — ignoring`);
    }

    return new Response("OK", { status: 200 });

  } catch (e) {
    console.error("[paypal-webhook] Uncaught error:", e);
    return new Response("Error", { status: 500 });
  }
});
