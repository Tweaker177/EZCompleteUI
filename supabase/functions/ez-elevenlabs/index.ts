import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const EL_API_KEY    = Deno.env.get("ELEVENLABS_API_KEY")!;
const DEFAULT_MODEL = "eleven_multilingual_v2";

// Safe base64 encoding that doesn't blow the call stack on large audio buffers.
// btoa(String.fromCharCode(...new Uint8Array(buf))) overflows for anything > ~200KB
// because spreading a huge typed array into function arguments exhausts the stack.
function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunkSize = 8192;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
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

    const { data: sub } = await supabase
      .from("subscriptions")
      .select("status, current_period_end")
      .eq("user_id", user.id)
      .single();

    if (!sub || sub.status !== "active" || new Date(sub.current_period_end) < new Date()) {
      return new Response(JSON.stringify({ error: "No active subscription" }), { status: 403 });
    }

    const body   = await req.json();
    const action = body.action;

    // ── fetch_voices ──────────────────────────────────────────────────────────
    if (action === "fetch_voices") {
      const res  = await fetch("https://api.elevenlabs.io/v1/voices", {
        headers: { "xi-api-key": EL_API_KEY }
      });
      const data = await res.json();
      return new Response(JSON.stringify(data), {
        headers: { "Content-Type": "application/json" }
      });
    }

    // ── tts ───────────────────────────────────────────────────────────────────
    if (action === "tts") {
      const { text, voice_id, output_format, speed } = body;
      if (!text || !voice_id) {
        return new Response(JSON.stringify({ error: "Missing text or voice_id" }), { status: 400 });
      }

      const fmt        = output_format || "mp3_44100_128";
      const speedValue = typeof speed === "number"
        ? Math.min(1.2, Math.max(0.7, speed))
        : 1.0;

      const elHeaders = {
        "xi-api-key":   EL_API_KEY,
        "Content-Type": "application/json",
      };
      const elBody = JSON.stringify({
        text:           text,
        model_id:       DEFAULT_MODEL,
        voice_settings: { speed: speedValue },
      });

      let res = await fetch(
        `https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=${fmt}`,
        { method: "POST", headers: elHeaders, body: elBody }
      );

      // Fallback to mp3 if plan doesn't support the requested format
      if (!res.ok && (res.status === 402 || res.status === 403)) {
        res = await fetch(
          `https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=mp3_44100_128`,
          { method: "POST", headers: elHeaders, body: elBody }
        );
        if (!res.ok) {
          return new Response(JSON.stringify({ error: "TTS failed" }), { status: 500 });
        }
      } else if (!res.ok) {
        const errText = await res.text();
        return new Response(JSON.stringify({ error: errText }), { status: res.status });
      }

      const audioBuffer = await res.arrayBuffer();
      const b64         = arrayBufferToBase64(audioBuffer);  // safe chunked encoding
      const usedFmt     = res.url.includes("mp3_44100_128") ? "mp3_44100_128" : fmt;
      const mime        = usedFmt.includes("mp3") ? "audio/mpeg"
                        : usedFmt.includes("wav") ? "audio/wav"
                        : "audio/mpeg";

      return new Response(JSON.stringify({
        audio_b64: b64,
        mime_type: mime,
        format:    usedFmt,
      }), { headers: { "Content-Type": "application/json" } });
    }

    // ── clone_voice ───────────────────────────────────────────────────────────
    if (action === "clone_voice") {
      const { name, audio_b64, filename } = body;
      if (!name || !audio_b64) {
        return new Response(JSON.stringify({ error: "Missing name or audio" }), { status: 400 });
      }

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
      }
      return new Response(JSON.stringify(data), {
        headers: { "Content-Type": "application/json" }
      });
    }

    // ── delete_voice ──────────────────────────────────────────────────────────
    if (action === "delete_voice") {
      const { voice_id } = body;
      if (!voice_id) {
        return new Response(JSON.stringify({ error: "Missing voice_id" }), { status: 400 });
      }

      await fetch(`https://api.elevenlabs.io/v1/voices/${voice_id}`, {
        method:  "DELETE",
        headers: { "xi-api-key": EL_API_KEY },
      });

      await supabase.from("user_voices")
        .delete()
        .eq("user_id", user.id)
        .eq("voice_id", voice_id);

      return new Response(JSON.stringify({ success: true }), {
        headers: { "Content-Type": "application/json" }
      });
    }

    return new Response(JSON.stringify({ error: "Unknown action" }), { status: 400 });

  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: "Server error" }), { status: 500 });
  }
});
