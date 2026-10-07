import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const AVATAR_BUCKET = "br-slot-avatars";
const headers = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type", "Content-Type": "application/json" };
const json = (body: Record<string, unknown>, status = 200) => new Response(JSON.stringify(body), { status, headers });
const validRoom = (value: unknown) => typeof value === "string" && /^[a-z0-9:_-]{1,100}$/i.test(value);
const cleanName = (value: unknown) => typeof value === "string" ? value.trim().replace(/\s+/g, " ").slice(0, 28) : "";
const cleanMessage = (value: unknown) => typeof value === "string" ? value.trim().replace(/\s+/g, " ").slice(0, 280) : "";
async function publicProfile(db: ReturnType<typeof createClient>, profile: Record<string, unknown> | null) {
  if (!profile) return null;
  let avatar_url: string | null = null;
  if (typeof profile.avatar_path === "string" && profile.avatar_path.length) {
    const { data } = await db.storage.from(AVATAR_BUCKET).createSignedUrl(profile.avatar_path, 3600);
    avatar_url = data?.signedUrl || null;
  }
  return { ...profile, avatar_url };
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Sign in required" }, 401);
  const db = createClient(URL, KEY, { auth: { persistSession: false } });
  const { data: auth } = await db.auth.getUser(token);
  const user = auth?.user;
  if (!user) return json({ error: "Unauthorized" }, 401);
  try {
    const body = await req.json(); const action = body.action;
    if (action === "profile") {
      const { data } = await db.from("br_player_profiles").select("display_name,avatar_path,music_enabled").eq("user_id", user.id).maybeSingle();
      return json({ profile: await publicProfile(db, data) });
    }
    if (action === "save_profile") {
      const name = cleanName(body.display_name);
      if (name.length < 2) return json({ error: "Choose a display name with at least 2 characters." }, 400);
      let avatarPath: string | undefined;
      if (typeof body.avatar_b64 === "string" && body.avatar_b64.length) {
        const bytes = Uint8Array.from(atob(body.avatar_b64), c => c.charCodeAt(0));
        if (bytes.byteLength > 3 * 1024 * 1024) return json({ error: "Profile photo must be under 3 MB." }, 400);
        avatarPath = `${user.id}/avatar-${Date.now()}.jpg`;
        const { error } = await db.storage.from(AVATAR_BUCKET).upload(avatarPath, bytes, { contentType: "image/jpeg", upsert: false });
        if (error) return json({ error: "Could not save profile photo." }, 500);
      }
      const update: Record<string, unknown> = { user_id: user.id, display_name: name, music_enabled: body.music_enabled === true, updated_at: new Date().toISOString() };
      if (avatarPath) update.avatar_path = avatarPath;
      const { data, error } = await db.from("br_player_profiles").upsert(update).select("display_name,avatar_path,music_enabled").single();
      if (error) return json({ error: "Could not save profile." }, 500);
      return json({ profile: await publicProfile(db, data) });
    }
    if (!validRoom(body.room_id)) return json({ error: "Invalid room." }, 400);
    const room = body.room_id as string;
    await db.from("br_slot_room_presence").upsert({ room_id: room, user_id: user.id, last_seen_at: new Date().toISOString() });
    if (action === "send") {
      const message = cleanMessage(body.message);
      if (!message.length) return json({ error: "Write a message first." }, 400);
      const { data: last } = await db.from("br_slot_room_messages").select("created_at").eq("room_id", room).eq("user_id", user.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (last && Date.now() - new Date(last.created_at).getTime() < 1800) return json({ error: "Please wait a moment before sending another message." }, 429);
      const { error } = await db.from("br_slot_room_messages").insert({ room_id: room, user_id: user.id, body: message });
      if (error) return json({ error: "Could not send message." }, 500);
      return json({ ok: true });
    }
    if (action === "report") {
      if (typeof body.message_id !== "string" || !cleanMessage(body.reason).length) return json({ error: "Choose a reason for the report." }, 400);
      await db.from("br_slot_room_reports").upsert({ message_id: body.message_id, reporter_id: user.id, reason: cleanMessage(body.reason) }, { onConflict: "message_id,reporter_id" });
      return json({ ok: true });
    }
    const cutoff = new Date(Date.now() - 90_000).toISOString();
    const [{ data: profile }, { data: messages }, { count }] = await Promise.all([
      db.from("br_player_profiles").select("display_name,avatar_path,music_enabled").eq("user_id", user.id).maybeSingle(),
      db.from("br_slot_room_messages").select("id,user_id,body,created_at").eq("room_id", room).is("deleted_at", null).order("created_at", { ascending: false }).limit(50),
      db.from("br_slot_room_presence").select("user_id", { count: "exact", head: true }).eq("room_id", room).gte("last_seen_at", cutoff),
    ]);
    const ids = [...new Set((messages || []).map(m => m.user_id))];
    const { data: profiles } = ids.length ? await db.from("br_player_profiles").select("user_id,display_name,avatar_path").in("user_id", ids) : { data: [] };
    const enrichedProfiles = await Promise.all((profiles || []).map(async p => [p.user_id, await publicProfile(db, p)] as const));
    const byID = new Map(enrichedProfiles);
    return json({ profile: await publicProfile(db, profile), active_players: count || 0, messages: (messages || []).reverse().map(m => ({ ...m, display_name: byID.get(m.user_id)?.display_name || "Player", avatar_url: byID.get(m.user_id)?.avatar_url || null, is_mine: m.user_id === user.id })) });
  } catch (error) { console.error("[br-slot-social]", error); return json({ error: "Room service is temporarily unavailable." }, 500); }
});
