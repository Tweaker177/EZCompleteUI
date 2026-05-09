import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const EL_API_KEY    = Deno.env.get("ELEVENLABS_API_KEY")!;
const DEFAULT_MODEL = "eleven_multilingual_v2";
const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// TTS coin rate: 1 coin per 50 characters, rounded up
function ttsCoinCost(charCount: number): number {
  return Math.ceil(charCount / 50);
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Content-Type": "application/json",
  };
}

function jsonResponse(body: object, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders(),
  });
}

// ── Coin helpers (inline — avoids an extra network hop to ez-entitlements) ───

async function getBalance(
  supabase: ReturnType<typeof createClient>,
  userId: string
): Promise<{ balance: number; tier: string } | null> {
  const { data, error } = await supabase
    .from("subscriptions")
    .select("coins_balance, tier")
    .eq("user_id", userId)
    .single();
  if (error || !data) return null;
  return { balance: data.coins_balance ?? 0, tier: data.tier ?? "basic" };
}

async function deductCoins(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  currentBalance: number,
  cost: number,
  feature: string
): Promise<number> {
  const newBalance = currentBalance - cost;
  await supabase
    .from("subscriptions")
    .update({ coins_balance: newBalance, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  if (cost > 0) {
    await supabase.from("coin_transactions").insert({
      user_id:       userId,
      amount:        cost,
      direction:     "debit",
      feature:       feature,
      description:   `Used ${feature}`,
      balance_after: newBalance,
    });
  }
  return newBalance;
}

// ── Main handler ──────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonResponse({ error: "No auth" }, 401);
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

    const jwt = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(jwt);
    if (userError || !user) {
      return jsonResponse({ error: "Invalid token" }, 401);
    }

    const body   = await req.json();
    const action = body.action as string;

    // ── fetch_voices — free, no coin cost ────────────────────────────────────
    if (action === "fetch_voices") {
      const res  = await fetch("https://api.elevenlabs.io/v1/voices", {
        headers: { "xi-api-key": EL_API_KEY },
      });
      const data = await res.json();
      return jsonResponse(data);
    }

    // ── tts ───────────────────────────────────────────────────────────────────
    // Required body fields:
    //   text          (string)
    //   voice_id      (string)
    //   output_format (string, optional — defaults to mp3_44100_128)
    //   speed         (number, optional — 0.7–1.2, defaults to 1.0)
    //   char_count    (number, optional — if omitted, derived from text.length)
    if (action === "tts") {
      const { text, voice_id, output_format, speed, char_count } = body;

      if (!text || !voice_id) {
        return jsonResponse({ error: "Missing text or voice_id" }, 400);
      }

      // Coin check
      const charCount  = typeof char_count === "number" ? char_count : (text as string).length;
      const coinCost   = ttsCoinCost(charCount);
      const acct       = await getBalance(supabase, user.id);

      if (!acct) {
        return jsonResponse({ error: "No account found" }, 403);
      }
      if (acct.balance < coinCost) {
        return jsonResponse({
          error:   "Insufficient coins",
          balance: acct.balance,
          cost:    coinCost,
        }, 402);
      }

      // Deduct before calling ElevenLabs
      const newBalance = await deductCoins(
        supabase, user.id, acct.balance, coinCost, "tts"
      );

      // Build ElevenLabs request
      const fmt        = (output_format as string) || "mp3_44100_128";
      const speedValue = typeof speed === "number"
        ? Math.min(1.2, Math.max(0.7, speed))
        : 1.0;

      const elBody = {
        text:           text,
        model_id:       DEFAULT_MODEL,
        voice_settings: { speed: speedValue },
      };

      const url = `https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=${fmt}`;

      const doELRequest = async (fmt: string) =>
        fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=${fmt}`, {
          method:  "POST",
          headers: { "xi-api-key": EL_API_KEY, "Content-Type": "application/json" },
          body:    JSON.stringify(elBody),
        });

      let res = await doELRequest(fmt);

      // Fallback to mp3 if plan doesn't support requested format
      if (!res.ok && (res.status === 402 || res.status === 403)) {
        console.log(`[ez-elevenlabs] Format ${fmt} rejected (${res.status}), falling back to mp3_44100_128`);
        res = await doELRequest("mp3_44100_128");
        if (!res.ok) {
          // Refund coins since we couldn't deliver
          await supabase
            .from("subscriptions")
            .update({ coins_balance: acct.balance, updated_at: new Date().toISOString() })
            .eq("user_id", user.id);
          await supabase.from("coin_transactions").insert({
            user_id:       user.id,
            amount:        coinCost,
            direction:     "credit",
            feature:       "tts",
            description:   "Refund: TTS failed after format fallback",
            balance_after: acct.balance,
          });
          return jsonResponse({ error: "TTS failed" }, 500);
        }
      } else if (!res.ok) {
        const errText = await res.text();
        // Refund on any ElevenLabs error
        await supabase
          .from("subscriptions")
          .update({ coins_balance: acct.balance, updated_at: new Date().toISOString() })
          .eq("user_id", user.id);
        await supabase.from("coin_transactions").insert({
          user_id:       user.id,
          amount:        coinCost,
          direction:     "credit",
          feature:       "tts",
          description:   `Refund: ElevenLabs error ${res.status}`,
          balance_after: acct.balance,
        });
        return jsonResponse({ error: errText }, res.status);
      }

      const audioData  = await res.arrayBuffer();
      const b64        = btoa(String.fromCharCode(...new Uint8Array(audioData)));
      const usedFmt    = res.url.includes("mp3_44100_128") ? "mp3_44100_128" : fmt;
      const mime       = usedFmt.includes("mp3") ? "audio/mpeg"
                       : usedFmt.includes("wav") ? "audio/wav"
                       : "audio/mpeg";

      console.log(`[ez-elevenlabs] TTS ok: ${charCount} chars, ${coinCost} coins, balance now ${newBalance}`);

      return jsonResponse({
        audio_b64:   b64,
        mime_type:   mime,
        format:      usedFmt,
        coins_spent: coinCost,
        balance:     newBalance,
      });
    }

    // ── clone_voice ───────────────────────────────────────────────────────────
    if (action === "clone_voice") {
      const { name, audio_b64, filename } = body;
      if (!name || !audio_b64) {
        return jsonResponse({ error: "Missing name or audio" }, 400);
      }

      // Coin check for voice clone
      const acct = await getBalance(supabase, user.id);
      if (!acct) return jsonResponse({ error: "No account found" }, 403);

      const CLONE_COST = 25;
      if (acct.balance < CLONE_COST) {
        return jsonResponse({
          error:   "Insufficient coins",
          balance: acct.balance,
          cost:    CLONE_COST,
        }, 402);
      }

      const newBalance = await deductCoins(
        supabase, user.id, acct.balance, CLONE_COST, "voice_clone"
      );

      const audioBytes = Uint8Array.from(atob(audio_b64), (c) => c.charCodeAt(0));
      const formData   = new FormData();
      formData.append("name", name);
      formData.append("description", "Created via EZCompleteUI");
      formData.append(
        "files",
        new Blob([audioBytes], { type: "audio/mpeg" }),
        filename || "audio.mp3"
      );

      const res  = await fetch("https://api.elevenlabs.io/v1/voices/add", {
        method:  "POST",
        headers: { "xi-api-key": EL_API_KEY },
        body:    formData,
      });
      const data = await res.json();

      if (data.voice_id) {
        await supabase.from("user_voices").insert({
          user_id:    user.id,
          voice_id:   data.voice_id,
          voice_name: name,
        });
      } else {
        // Refund if ElevenLabs didn't return a voice_id (clone failed)
        await supabase
          .from("subscriptions")
          .update({ coins_balance: acct.balance, updated_at: new Date().toISOString() })
          .eq("user_id", user.id);
        await supabase.from("coin_transactions").insert({
          user_id:       user.id,
          amount:        CLONE_COST,
          direction:     "credit",
          feature:       "voice_clone",
          description:   "Refund: voice clone did not return voice_id",
          balance_after: acct.balance,
        });
      }

      return jsonResponse({ ...data, balance: data.voice_id ? newBalance : acct.balance });
    }

    // ── delete_voice — free ───────────────────────────────────────────────────
    if (action === "delete_voice") {
      const { voice_id } = body;
      if (!voice_id) {
        return jsonResponse({ error: "Missing voice_id" }, 400);
      }

      await fetch(`https://api.elevenlabs.io/v1/voices/${voice_id}`, {
        method:  "DELETE",
        headers: { "xi-api-key": EL_API_KEY },
      });

      await supabase
        .from("user_voices")
        .delete()
        .eq("user_id", user.id)
        .eq("voice_id", voice_id);

      return jsonResponse({ success: true });
    }

    return jsonResponse({ error: "Unknown action" }, 400);

  } catch (e) {
    console.error(e);
    return jsonResponse({ error: "Server error" }, 500);
  }
});
