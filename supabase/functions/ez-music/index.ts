// supabase/functions/ez-music/index.ts
// EZCompleteUI v1.1
//
// Changes from v1.0:
//   - Library paging cursor (`before`) is now inclusive (<=) so variants that
//     share a created_at are never skipped between pages. Clients must
//     de-duplicate rows by id; EZMusicViewController does.
//
// Purpose:
//   Server-authoritative ElevenLabs text-to-music. This function is the only
//   place that decides what a track costs, talks to ElevenLabs, stores the
//   audio, and moves coins. The app only sends what the user picked (prompt or
//   composition plan, duration, variant count) and displays what comes back.
//   No secrets live in the app binary; the ElevenLabs key is a function secret.
//
// Actions (POST JSON, `action` field):
//   config        → current prices and limits, for showing a price quote
//   generate      → reserve coins, start generating in the background, reply 202
//   status        → poll specific entries (entry_ids / generation_id) or list recent ones
//   signed_url    → short-lived playback or download link for a finished track
//   set_favorite  → star / unstar an entry
//   delete        → remove a finished or failed entry and its audio file
//
// Flow of a `generate` call:
//   1. Validate everything against music_config (never against client values).
//   2. reserve_music_generation debits the full price once, atomically, and
//      creates one pending entry per variant. Re-sending the same
//      generation_id returns the existing entries without charging again.
//   3. Reply 202 right away. Each variant then runs in the background
//      (EdgeRuntime.waitUntil) so closing the app does not abort the job.
//   4. Each variant calls ElevenLabs (retrying 429/502/503/504 and network
//      errors), uploads the MP3 to the private music-assets bucket, and settles
//      via finalize_music_attempt: keep the charge for a usable file, refund
//      otherwise. Settlement is idempotent.
//   5. Reservations whose background job died are refunded by
//      reap_stale_music_attempts, called opportunistically on every request.
//
// Required secrets:   ELEVENLABS_API_KEY (confirm the name matches ez-elevenlabs)
// Required migration: 20261012000100_add_music_generation.sql
//
// v1.0 — Initial version.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Supabase's runtime global for work that continues after the response is sent.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

// ── Constants ────────────────────────────────────────────────────────────────

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ELEVENLABS_URL = "https://api.elevenlabs.io/v1/music";
const ELEVENLABS_VIDEO_TO_MUSIC_URL = "https://api.elevenlabs.io/v1/music/video-to-music";
const STORAGE_BUCKET = "music-assets";

// v2.5 is the current high-quality Music model. The public API still defaults
// to v1 during ElevenLabs' transition unless we explicitly select a v2 model,
// so never rely on the provider default here.
const ALLOWED_MODELS = ["music_v2_5", "music_v2", "music_v1"];
const DEFAULT_MODEL = "music_v2_5";

// output_format → bitrate in bits per second (used to estimate duration from size).
const ALLOWED_FORMATS: Record<string, number> = {
  mp3_44100_128: 128_000,
  mp3_44100_192: 192_000,
  mp3_48000_192: 192_000,
};
const DEFAULT_FORMAT = "mp3_48000_192";
const FALLBACK_FORMAT = "mp3_44100_128";

const PROMPT_MAX_CHARS = 4100;        // ElevenLabs limit for `prompt`
const TITLE_MAX_CHARS = 120;
const PLAN_MAX_JSON_CHARS = 20_000;
const PLAN_MAX_SECTIONS = 30;
const PLAN_MIN_SECTION_MS = 3_000;
const MAX_REFERENCE_BYTES = 12 * 1024 * 1024;
const MAX_REFERENCE_DURATION_MS = 120_000;
const MAX_PROVIDER_ATTEMPTS = 3;
const MAX_RETRY_DELAY_MS = 15_000;
const VIDEO_PROVIDER_TIMEOUT_MS = 280_000;
const MIN_USABLE_AUDIO_BYTES = 4_096;
// A track shorter than this fraction of the requested length is billed by its
// real length instead of the requested one.
const SHORT_TRACK_THRESHOLD = 0.9;
const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);
const STATUS_LIST_LIMIT_MAX = 50;

// Defaults used only if a music_config row is missing or malformed.
const CONFIG_DEFAULTS = {
  music_enabled: 1,
  provider_music_rate_usd_per_minute: 0.15,
  max_song_duration_seconds: 300,
  minimum_song_duration_seconds: 10,
  coins_per_minute: 30,
  minimum_generation_charge: 5,
  variant_count_limit: 3,
  max_concurrent_generations: 3,
  stale_reservation_minutes: 15,
  provider_deadline_seconds: 140,
  signed_url_ttl_seconds: 3600,
};
type MusicConfig = typeof CONFIG_DEFAULTS;

// ── Response helpers ─────────────────────────────────────────────────────────

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Content-Type": "application/json",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}

function errorResponse(status: number, code: string, message: string, extra: Record<string, unknown> = {}): Response {
  return jsonResponse({ success: false, error: code, message, ...extra }, status);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// ── Configuration and pricing ────────────────────────────────────────────────

async function loadConfig(service: SupabaseClient): Promise<MusicConfig> {
  const config: MusicConfig = { ...CONFIG_DEFAULTS };
  const { data, error } = await service.from("music_config").select("key, value_numeric");
  if (error) {
    console.error("[ez-music] music_config read failed, using defaults:", error.message);
    return config;
  }
  for (const row of data ?? []) {
    const value = Number(row.value_numeric);
    if (row.key in config && Number.isFinite(value)) {
      (config as Record<string, number>)[row.key] = value;
    }
  }
  return config;
}

// The one pricing rule: per-minute rate, rounded up, never below the minimum.
function coinsForMilliseconds(config: MusicConfig, durationMs: number): number {
  const rawCoins = Math.ceil((durationMs / 60_000) * config.coins_per_minute);
  return Math.max(config.minimum_generation_charge, rawCoins);
}

function providerCostUsd(config: MusicConfig, durationMs: number): number {
  return (durationMs / 60_000) * config.provider_music_rate_usd_per_minute;
}

// ── Request validation ───────────────────────────────────────────────────────

interface GenerateRequest {
  generationId: string;
  title: string;
  prompt: string | null;
  compositionPlan: Record<string, unknown> | null;
  forceInstrumental: boolean;
  modelId: string;
  outputFormat: string;
  durationMs: number;
  variantCount: number;
  lyrics: string | null;
  reference: ReferenceUpload | null;
}

type ReferenceMode = "style" | "source";
interface ReferenceUpload {
  audio: Uint8Array;
  filename: string;
  mimeType: string;
  mode: ReferenceMode;
  durationMs: number;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Returns either a validated request or a human-readable reason it was refused.
function validateGenerateRequest(body: Record<string, unknown>, config: MusicConfig):
  { request: GenerateRequest } | { reason: string } {

  const generationId = String(body.generation_id ?? "");
  if (!UUID_PATTERN.test(generationId)) {
    return { reason: "generation_id must be a UUID created by the app for this request." };
  }

  const rawPrompt = typeof body.prompt === "string" ? body.prompt.trim() : "";
  const lyrics = typeof body.lyrics === "string" ? body.lyrics.trim() : "";
  const compositionPlan = body.composition_plan && typeof body.composition_plan === "object"
    ? body.composition_plan as Record<string, unknown> : null;
  if (rawPrompt && compositionPlan) {
    return { reason: "Send either a prompt or a composition plan, not both." };
  }
  if (!rawPrompt && !compositionPlan) {
    return { reason: "Describe the music you want." };
  }
  if (rawPrompt.length > PROMPT_MAX_CHARS) {
    return { reason: `The description is too long (max ${PROMPT_MAX_CHARS} characters).` };
  }
  if (lyrics.length > 6_100) return { reason: "Lyrics are too long (max 6,100 characters)." };

  let reference: ReferenceUpload | null = null;
  if (body.reference !== undefined && body.reference !== null) {
    const rawReference = body.reference as Record<string, unknown>;
    const encoded = typeof rawReference.audio_base64 === "string" ? rawReference.audio_base64 : "";
    const filename = typeof rawReference.filename === "string" ? rawReference.filename.slice(0, 160) : "reference.m4a";
    const mimeType = typeof rawReference.mime_type === "string" ? rawReference.mime_type.slice(0, 100) : "application/octet-stream";
    const mode: ReferenceMode = rawReference.mode === "source" ? "source" : "style";
    const durationMs = Number(rawReference.duration_ms ?? 0);
    if (!Number.isFinite(durationMs) || durationMs <= 0 || durationMs > MAX_REFERENCE_DURATION_MS) {
      return { reason: "Audio references must be 2 minutes or shorter. Choose a section of the song first." };
    }
    if (!encoded || encoded.length > Math.ceil(MAX_REFERENCE_BYTES * 4 / 3) + 8) {
      return { reason: "That audio reference is too large. Choose a clip under 12 MB." };
    }
    try {
      const binary = atob(encoded);
      const audio = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      if (!audio.length || audio.length > MAX_REFERENCE_BYTES) return { reason: "That audio reference is too large." };
      reference = { audio, filename, mimeType, mode, durationMs: Number.isFinite(durationMs) ? Math.max(0, Math.floor(durationMs)) : 0 };
    } catch { return { reason: "That audio reference could not be decoded." }; }
  }

  const modelId = String(body.model_id ?? DEFAULT_MODEL);
  if (!ALLOWED_MODELS.includes(modelId)) return { reason: "That music model is not available." };

  const outputFormat = String(body.output_format ?? DEFAULT_FORMAT);
  if (!(outputFormat in ALLOWED_FORMATS)) return { reason: "That audio format is not available." };

  const variantCount = Number(body.variant_count ?? 1);
  if (!Number.isInteger(variantCount) || variantCount < 1 || variantCount > config.variant_count_limit) {
    return { reason: `Choose between 1 and ${config.variant_count_limit} variants.` };
  }

  // Duration is always decided here: from the plan's sections, or from the
  // explicit length the user picked. The provider is never allowed to choose.
  let durationMs: number;
  if (compositionPlan) {
    const sections = (compositionPlan as { sections?: unknown }).sections;
    if (!Array.isArray(sections) || sections.length < 1 || sections.length > PLAN_MAX_SECTIONS) {
      return { reason: `A composition plan needs 1–${PLAN_MAX_SECTIONS} sections.` };
    }
    if (JSON.stringify(compositionPlan).length > PLAN_MAX_JSON_CHARS) {
      return { reason: "The composition plan is too large." };
    }
    durationMs = 0;
    for (const section of sections) {
      const sectionMs = Number((section as { duration_ms?: unknown })?.duration_ms);
      if (!Number.isInteger(sectionMs) || sectionMs < PLAN_MIN_SECTION_MS) {
        return { reason: `Every section needs a duration of at least ${PLAN_MIN_SECTION_MS / 1000} seconds.` };
      }
      durationMs += sectionMs;
    }
  } else {
    const seconds = Number(body.duration_seconds);
    if (!Number.isInteger(seconds)) return { reason: "Choose how long the song should be." };
    durationMs = seconds * 1000;
  }

  const minimumMs = config.minimum_song_duration_seconds * 1000;
  const maximumMs = config.max_song_duration_seconds * 1000;
  if (durationMs < minimumMs || durationMs > maximumMs) {
    return { reason: `Songs must be between ${config.minimum_song_duration_seconds} and ${config.max_song_duration_seconds} seconds.` };
  }

  const defaultTitle = (rawPrompt || "Untitled song").slice(0, 60);
  const title = (typeof body.title === "string" && body.title.trim() ? body.title.trim() : defaultTitle)
    .slice(0, TITLE_MAX_CHARS);

  return {
    request: {
      generationId,
      title,
      prompt: rawPrompt || null,
      compositionPlan,
      forceInstrumental: body.force_instrumental === true,
      modelId,
      outputFormat,
      durationMs,
      variantCount,
      lyrics: lyrics || null,
      reference,
    },
  };
}

// ── ElevenLabs client ────────────────────────────────────────────────────────

class ProviderError extends Error {
  constructor(
    public code: string,
    message: string,
    public httpStatus: number | null = null,
    public suggestion: string | null = null,
  ) { super(message); }
}

// A v2 audio-source chunk is replayed in the output.  A conditioning_ref, in
// contrast, only guides newly generated material.  Keep those meanings apart:
// it prevents a TTS clip from being treated as a useless "style" sample.
async function uploadReferenceToProvider(reference: ReferenceUpload, modelId: string): Promise<string> {
  const apiKey = Deno.env.get("ELEVENLABS_API_KEY");
  if (!apiKey) throw new ProviderError("provider_unavailable", "Music generation is temporarily unavailable.");
  const form = new FormData();
  form.append("file", new Blob([reference.audio], { type: reference.mimeType }), reference.filename);
  // Returning the extracted v2.5 plan is useful to ElevenLabs for inspecting
  // the upload, even though we construct the small, user-directed plan below.
  form.append("extract_composition_plan", modelId);
  const response = await fetch("https://api.elevenlabs.io/v1/music/upload", {
    method: "POST", headers: { "xi-api-key": apiKey }, body: form,
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 300);
    console.error(`[ez-music] reference upload failed (${response.status}): ${detail}`);
    if (response.status === 400 || response.status === 422) {
      throw new ProviderError("reference_rejected", "That audio could not be used as a music reference.", response.status);
    }
    throw new ProviderError("provider_unavailable", "The music service could not upload that reference.", response.status);
  }
  const payload = await response.json().catch(() => null) as Record<string, unknown> | null;
  const songId = typeof payload?.song_id === "string" ? payload.song_id : "";
  if (!songId) throw new ProviderError("reference_upload_failed", "The music service did not return a usable audio reference.");
  return songId;
}

function stylesForPrompt(prompt: string): string[] {
  // v2.5 benefits from concrete early-chunk directions.  The prompt remains
  // one direction while these ensure an intentional, coherent starting point.
  // ElevenLabs caps each individual style descriptor at 200 characters.
  return [prompt.slice(0, 200), "high fidelity production", "cohesive arrangement",
    "expressive performance", "clear dynamics", "balanced mix", "musical development"];
}

function lyricStyles(prompt: string, firstChunk: boolean): string[] {
  const vocalDirection = ["lead singer performs the supplied lyrics", "clear intelligible sung words", "vocal-forward mix"];
  return firstChunk ? [...stylesForPrompt(prompt), ...vocalDirection]
    : ["cohesive continuation", "same lead singer", "continue singing the supplied lyrics", "clear intelligible words"];
}

function buildReferencePlan(request: GenerateRequest, songId: string): Record<string, unknown> {
  const generatedChunk: Record<string, unknown> = {
    text: request.lyrics ? `[Song]\n${request.lyrics}` : "{Instrumental musical development}",
    duration_ms: request.durationMs,
    positive_styles: request.lyrics ? lyricStyles(request.prompt ?? "original music", true) : stylesForPrompt(request.prompt ?? "original music"),
    negative_styles: request.lyrics ? ["instrumental-only", "wordless humming"] : [],
    context_adherence: "high",
  };
  // Conditioning is intentionally capped at 30 seconds.  Longer source clips
  // may be preserved in source mode, but forcing the model to condition on a
  // long clip makes continuation less predictable.
  const sourceEndMs = Math.max(3_000, Math.min(request.reference?.durationMs || 600_000, 600_000));
  const range = { start_ms: 0, end_ms: request.reference?.mode === "style" ? Math.min(sourceEndMs, 30_000) : sourceEndMs };
  if (request.reference?.mode === "style") {
    // Conditioning affects new material only; the uploaded clip is never
    // copied into the result.  The first generated chunk has the broadest
    // influence, so attach it there at high adherence.
    generatedChunk.conditioning_ref = { song_id: songId, range };
    generatedChunk.condition_strength = "high";
    return { chunks: [generatedChunk] };
  }
  // Source chunks preserve the actual reference in the resulting song.  The
  // following generation is deliberately high-adherence so it joins cleanly.
  return { chunks: [{ song_id: songId, range }, generatedChunk] };
}

function buildLyricsPlan(request: GenerateRequest): Record<string, unknown> {
  // ElevenLabs allows a full song, but each lyric *line* must be <=200 chars,
  // with no more than 30 lines in a chunk.  Preserve the writer's line breaks
  // and split only an overlong line at word boundaries.
  const lyricLines: string[] = [];
  for (const rawLine of (request.lyrics ?? "").replace(/\r/g, "").split("\n")) {
    let remaining = rawLine.trim();
    while (remaining.length > 200) {
      let splitAt = remaining.lastIndexOf(" ", 200);
      if (splitAt < 1) splitAt = 200;
      lyricLines.push(remaining.slice(0, splitAt).trim());
      remaining = remaining.slice(splitAt).trim();
    }
    if (remaining) lyricLines.push(remaining);
  }
  const chunkCount = Math.max(Math.ceil(request.durationMs / 120_000), Math.ceil(lyricLines.length / 30));
  const chunks: Record<string, unknown>[] = [];
  let consumedDuration = 0;
  for (let index = 0; index < chunkCount; index++) {
    const remainingChunks = chunkCount - index;
    const duration = Math.floor((request.durationMs - consumedDuration) / remainingChunks);
    consumedDuration += duration;
    const start = Math.floor(index * lyricLines.length / chunkCount);
    const end = Math.floor((index + 1) * lyricLines.length / chunkCount);
    const lyricText = lyricLines.slice(start, end).join("\n");
    chunks.push({
      text: lyricText
        ? `[${index === 0 ? "Verse" : index === chunkCount - 1 ? "Chorus" : `Verse ${index + 1}`}]\n${lyricText}`
        : `[Instrumental]\n{instrumental continuation}`,
      duration_ms: duration,
      positive_styles: lyricText ? lyricStyles(request.prompt ?? "original music", index === 0)
        : ["cohesive instrumental continuation"],
      negative_styles: lyricText ? ["instrumental-only", "wordless humming"] : ["vocals", "lyrics"],
      context_adherence: "high",
    });
  }
  return { chunks };
}

interface ProviderResult {
  audio: Uint8Array;
  songId: string | null;
  providerRequestId: string | null;
  attempts: number;
  formatUsed: string;
}

function providerMessage(value: unknown): string {
  if (typeof value === "string") return value.trim().slice(0, 280);
  if (Array.isArray(value)) {
    for (const item of value) { const message = providerMessage(item); if (message) return message; }
    return "";
  }
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    for (const key of ["message", "reason", "msg", "detail", "error"]) {
      const message = providerMessage(record[key]);
      if (message) return message;
    }
  }
  return "";
}

// Pulls the useful parts out of ElevenLabs' 400/422 bodies (bad_prompt etc.).
function interpretProviderRejection(httpStatus: number, bodyText: string): ProviderError {
  let detail: Record<string, unknown> | null = null;
  try {
    const parsed = JSON.parse(bodyText);
    detail = (parsed?.detail && typeof parsed.detail === "object") ? parsed.detail : parsed;
  } catch { /* body was not JSON */ }

  const status = String((detail as { status?: unknown })?.status ?? "");
  const data = ((detail as { data?: Record<string, unknown> })?.data ?? {}) as Record<string, unknown>;
  const providerDetail = JSON.stringify(detail ?? {}).toLowerCase();
  const reason = providerMessage(detail) || bodyText.trim().slice(0, 280);
  if (status === "bad_prompt") {
    return new ProviderError("prompt_rejected",
      "That description can't be used (it may reference copyrighted material or protected names).",
      httpStatus, typeof data.prompt_suggestion === "string" ? data.prompt_suggestion : null);
  }
  if (status === "bad_composition_plan") {
    if (/duration|120.?000|chunk/.test(providerDetail)) {
      return new ProviderError("plan_duration_invalid",
        "The lyrics could not fit the selected song length. Try generating it again.", httpStatus, null);
    }
    if (/copyright|protected|artist|artist_name/.test(providerDetail)) {
      return new ProviderError("plan_rejected",
        "The lyrics or style request references protected material. Remove artist names or copyrighted lyrics and try again.",
        httpStatus, null);
    }
    return new ProviderError("plan_rejected",
      "The music service could not use the lyric structure. Try shorter lines or add section labels such as [Verse] and [Chorus].",
      httpStatus, null);
  }
  return new ProviderError("invalid_request",
    reason ? `The music service rejected this request: ${reason}` : "The music service could not process that request.",
    httpStatus);
}

async function requestProviderOnce(
  apiKey: string, body: Record<string, unknown>, outputFormat: string, timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(`${ELEVENLABS_URL}?output_format=${encodeURIComponent(outputFormat)}`, {
      method: "POST",
      headers: { "xi-api-key": apiKey, "Content-Type": "application/json", "Accept": "audio/mpeg" },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

// Calls ElevenLabs, retrying transient failures inside the time budget, and
// falling back to the 128 kbps format if the account can't produce 192 kbps.
async function generateWithProvider(
  request: GenerateRequest, config: MusicConfig,
): Promise<ProviderResult> {
  const apiKey = Deno.env.get("ELEVENLABS_API_KEY");
  if (!apiKey) {
    console.error("[ez-music] ELEVENLABS_API_KEY secret is not set");
    throw new ProviderError("provider_unavailable", "Music generation is temporarily unavailable.");
  }

  const body: Record<string, unknown> = { model_id: request.modelId };
  if (request.compositionPlan) {
    body.composition_plan = request.compositionPlan;
  } else {
    body.prompt = request.prompt;
    body.music_length_ms = request.durationMs;
    if (request.forceInstrumental) body.force_instrumental = true;
  }

  const startedAt = Date.now();
  const deadlineMs = config.provider_deadline_seconds * 1000;
  let outputFormat = request.outputFormat;
  let lastError: ProviderError | null = null;

  for (let attempt = 1; attempt <= MAX_PROVIDER_ATTEMPTS; attempt++) {
    const remainingMs = deadlineMs - (Date.now() - startedAt);
    if (remainingMs < 10_000) break;

    let retryDelayMs = 2_000 * attempt;
    try {
      const response = await requestProviderOnce(apiKey, body, outputFormat, remainingMs);

      if (response.ok) {
        const audio = new Uint8Array(await response.arrayBuffer());
        return {
          audio,
          songId: response.headers.get("song-id"),
          providerRequestId: response.headers.get("request-id"),
          attempts: attempt,
          formatUsed: outputFormat,
        };
      }

      const bodyText = await response.text().catch(() => "");

      if (response.status === 401 || response.status === 403) {
        // The 192 kbps format needs a higher ElevenLabs tier; drop to 128 and retry once.
        if (outputFormat !== FALLBACK_FORMAT && /output_format|tier|subscription/i.test(bodyText)) {
          outputFormat = FALLBACK_FORMAT;
          continue;
        }
        // Bad key or exhausted credits: not the user's problem, but the owner must know.
        console.error(`[ez-music] ElevenLabs auth/quota failure (${response.status}): ${bodyText.slice(0, 300)}`);
        throw new ProviderError("provider_unavailable", "Music generation is temporarily unavailable.", response.status);
      }

      if (RETRYABLE_STATUS.has(response.status)) {
        const retryAfterSeconds = Number(response.headers.get("retry-after"));
        if (Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0) {
          retryDelayMs = Math.min(retryAfterSeconds * 1000, MAX_RETRY_DELAY_MS);
        }
        lastError = new ProviderError("provider_busy",
          "The music service is busy. Please try again shortly.", response.status);
      } else if (response.status === 400 || response.status === 422) {
        if (outputFormat !== FALLBACK_FORMAT && /output_format/i.test(bodyText)) {
          outputFormat = FALLBACK_FORMAT;
          continue;
        }
        throw interpretProviderRejection(response.status, bodyText);
      } else {
        console.error(`[ez-music] ElevenLabs unexpected ${response.status}: ${bodyText.slice(0, 300)}`);
        throw new ProviderError("provider_error", "The music service returned an error.", response.status);
      }
    } catch (caught) {
      if (caught instanceof ProviderError) throw caught;
      const timedOut = caught instanceof DOMException && caught.name === "AbortError";
      lastError = new ProviderError(timedOut ? "provider_timeout" : "provider_network",
        timedOut ? "The music service took too long to respond." : "Could not reach the music service.");
      if (timedOut) break; // The budget is spent; another attempt cannot finish.
    }

    if (attempt < MAX_PROVIDER_ATTEMPTS) await sleep(retryDelayMs);
  }

  throw lastError ?? new ProviderError("provider_timeout", "The music service took too long to respond.");
}

// ── Audio helpers ────────────────────────────────────────────────────────────

// MP3 files start with an ID3 tag or an 11-bit frame sync (0xFF 0xE0+).
function looksLikeMp3(audio: Uint8Array): boolean {
  if (audio.length < 3) return false;
  const hasId3Tag = audio[0] === 0x49 && audio[1] === 0x44 && audio[2] === 0x33;
  const hasFrameSync = audio[0] === 0xff && (audio[1] & 0xe0) === 0xe0;
  return hasId3Tag || hasFrameSync;
}

// Constant-bitrate estimate; ElevenLabs does not return the duration.
function estimateDurationMs(byteLength: number, bitsPerSecond: number): number {
  return Math.round((byteLength * 8 / bitsPerSecond) * 1000);
}

async function uploadWithRetry(service: SupabaseClient, path: string, audio: Uint8Array): Promise<boolean> {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const { error } = await service.storage.from(STORAGE_BUCKET)
      .upload(path, audio, { contentType: "audio/mpeg", upsert: true });
    if (!error) return true;
    console.error(`[ez-music] upload attempt ${attempt} failed for ${path}: ${error.message}`);
    if (attempt < 3) await sleep(500 * attempt);
  }
  return false;
}

// ── Background worker: one variant ───────────────────────────────────────────

interface VariantJob {
  userId: string;
  attemptId: string;
  variantIndex: number;
  reservedCoins: number;
  request: GenerateRequest;
}

interface Settlement {
  outcome: "complete" | "failed";
  coinsCharged: number;
  errorCode: string | null;
  errorText: string | null;
  providerCost: number | null;
  providerRequestId: string | null;
  providerAttempts: number | null;
  actualMs: number | null;
  filePath: string | null;
  fileSize: number | null;
  songId: string | null;
}

function failedSettlement(code: string, text: string, providerAttempts: number | null = null): Settlement {
  return {
    outcome: "failed", coinsCharged: 0, errorCode: code, errorText: text, providerCost: null,
    providerRequestId: null, providerAttempts, actualMs: null, filePath: null, fileSize: null, songId: null,
  };
}

// Settlement is the step that returns or keeps real coins, so it retries.
async function settleAttempt(service: SupabaseClient, job: VariantJob, settlement: Settlement): Promise<boolean | null> {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const { data, error } = await service.rpc("finalize_music_attempt", {
      p_attempt_id: job.attemptId,
      p_outcome: settlement.outcome,
      p_coins_charged: settlement.coinsCharged,
      p_error_code: settlement.errorCode,
      p_error_text: settlement.errorText,
      p_provider_cost_usd: settlement.providerCost,
      p_provider_request_id: settlement.providerRequestId,
      p_provider_attempts: settlement.providerAttempts,
      p_duration_actual_ms: settlement.actualMs,
      p_file_path: settlement.filePath,
      p_file_size_bytes: settlement.fileSize,
      p_song_id: settlement.songId,
    });
    if (!error) return (data as { applied?: boolean })?.applied === true;
    console.error(`[ez-music] finalize attempt ${attempt} failed for ${job.attemptId}: ${error.message}`);
    if (attempt < 4) await sleep(400 * attempt);
  }
  // Left reserved on purpose: the stale-reservation reaper refunds it later.
  return null;
}

async function runVariant(service: SupabaseClient, config: MusicConfig, job: VariantJob): Promise<void> {
  const { request } = job;
  const filePath = `${job.userId}/${request.generationId}/${job.variantIndex}.mp3`;
  let settlement: Settlement;
  let uploadedPath: string | null = null;

  try {
    const result = await generateWithProvider(request, config);
    const bitsPerSecond = ALLOWED_FORMATS[result.formatUsed] ?? ALLOWED_FORMATS[DEFAULT_FORMAT];
    const actualMs = estimateDurationMs(result.audio.length, bitsPerSecond);
    const providerCost = providerCostUsd(config, actualMs);

    if (result.audio.length < MIN_USABLE_AUDIO_BYTES || !looksLikeMp3(result.audio)) {
      settlement = { ...failedSettlement("invalid_audio", "The music service returned an unusable file.", result.attempts),
        providerCost, providerRequestId: result.providerRequestId, songId: result.songId };
    } else if (!(await uploadWithRetry(service, filePath, result.audio))) {
      settlement = { ...failedSettlement("storage_failed", "The song was generated but could not be saved.", result.attempts),
        providerCost, providerRequestId: result.providerRequestId, songId: result.songId };
    } else {
      uploadedPath = filePath;
      // Charge the requested length unless the track came back clearly shorter.
      const chargedMs = actualMs < request.durationMs * SHORT_TRACK_THRESHOLD ? actualMs : request.durationMs;
      settlement = {
        outcome: "complete",
        coinsCharged: Math.min(job.reservedCoins, coinsForMilliseconds(config, chargedMs)),
        errorCode: null, errorText: null, providerCost,
        providerRequestId: result.providerRequestId, providerAttempts: result.attempts,
        actualMs, filePath, fileSize: result.audio.length, songId: result.songId,
      };
    }
  } catch (caught) {
    if (caught instanceof ProviderError) {
      settlement = { ...failedSettlement(caught.code, caught.suggestion
        ? `${caught.message} Try: ${caught.suggestion}` : caught.message) };
    } else {
      console.error("[ez-music] unexpected variant error:", caught);
      settlement = failedSettlement("internal_error", "Something went wrong while generating the song.");
    }
  }

  const applied = await settleAttempt(service, job, settlement);

  // If the reaper already refunded this attempt, the file must not linger unowned.
  if (applied === false && uploadedPath) {
    await service.storage.from(STORAGE_BUCKET).remove([uploadedPath]);
  }
}

function runInBackground(work: Promise<unknown>): Promise<unknown> | void {
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime) {
    EdgeRuntime.waitUntil(work);
    return;
  }
  return work; // Local `supabase functions serve` fallback: caller awaits it.
}

// ── Row shaping ──────────────────────────────────────────────────────────────

// Internal columns (file_path, provider cost, song id) never leave the server.
const PUBLIC_ENTRY_COLUMNS =
  "id, generation_id, title, prompt, model_id, duration_requested_ms, duration_actual_ms, " +
  "variant_index, output_format, file_size_bytes, coins_reserved, coins_charged, status, " +
  "error_code, error_text, is_downloadable, is_favorite, created_at, completed_at, composition_plan";

// Lyrics live inside the v2 composition plan rather than in a separate
// database field. Return only the user-facing words to the app—not provider
// style directives or source-audio references—so local libraries can preserve
// lyrics without exposing implementation details.
function lyricsFromCompositionPlan(rawPlan: unknown): string | null {
  const chunks = (rawPlan as { chunks?: unknown })?.chunks;
  if (!Array.isArray(chunks)) return null;
  const lines = chunks.map((chunk) => typeof (chunk as { text?: unknown })?.text === "string"
    ? (chunk as { text: string }).text.replace(/^\[[^\]]+\]\s*/m, "").trim() : "")
    .filter((text) => text.length > 0 && !/^\{instrumental/i.test(text));
  return lines.length ? lines.join("\n\n") : null;
}

function publicMusicEntry(row: Record<string, unknown>): Record<string, unknown> {
  const { composition_plan: compositionPlan, ...entry } = row;
  const lyrics = lyricsFromCompositionPlan(compositionPlan);
  return lyrics ? { ...entry, lyrics } : entry;
}

function publicConfig(config: MusicConfig) {
  return {
    enabled: config.music_enabled === 1,
    coins_per_minute: config.coins_per_minute,
    minimum_generation_charge: config.minimum_generation_charge,
    minimum_song_duration_seconds: config.minimum_song_duration_seconds,
    max_song_duration_seconds: config.max_song_duration_seconds,
    variant_count_limit: config.variant_count_limit,
    default_model_id: DEFAULT_MODEL,
    output_formats: Object.keys(ALLOWED_FORMATS),
  };
}

// ── Action handlers ──────────────────────────────────────────────────────────

async function handleGenerate(
  service: SupabaseClient, config: MusicConfig, userId: string, body: Record<string, unknown>,
): Promise<Response> {
  if (config.music_enabled !== 1) {
    return errorResponse(503, "music_disabled", "Music generation is temporarily unavailable.");
  }

  const validation = validateGenerateRequest(body, config);
  if ("reason" in validation) return errorResponse(400, "invalid_request", validation.reason);
  const request = validation.request;

  // Upload before reserving the app's generation coins.  An upload may be
  // rejected by the provider's copyright inspection; that must never leave a
  // user with a reserved generation that cannot be composed.
  try {
    if (request.reference) {
      const songId = await uploadReferenceToProvider(request.reference, request.modelId);
      request.compositionPlan = buildReferencePlan(request, songId);
    } else if (request.lyrics) {
      request.compositionPlan = buildLyricsPlan(request);
    }
  } catch (caught) {
    if (caught instanceof ProviderError) return errorResponse(422, caught.code, caught.message);
    console.error("[ez-music] preparing reference failed:", caught);
    return errorResponse(503, "provider_unavailable", "The music service is temporarily unavailable.");
  }

  const coinsPerVariant = coinsForMilliseconds(config, request.durationMs);

  const { data: reserved, error: reserveError } = await service.rpc("reserve_music_generation", {
    p_user_id: userId,
    p_generation_id: request.generationId,
    p_title: request.title,
    p_prompt: request.prompt,
    p_composition_plan: request.compositionPlan,
    p_model_id: request.modelId,
    p_duration_ms: request.durationMs,
    p_variant_count: request.variantCount,
    p_output_format: request.outputFormat,
    p_coins_per_variant: coinsPerVariant,
    p_max_active: config.max_concurrent_generations,
    p_request_payload: {
      prompt: request.prompt, composition_plan: request.compositionPlan,
      force_instrumental: request.forceInstrumental, model_id: request.modelId,
      output_format: request.outputFormat, duration_ms: request.durationMs,
    },
  });

  if (reserveError) {
    const reason = reserveError.message ?? "";
    if (reason.includes("insufficient_coins")) {
      return errorResponse(402, "insufficient_coins", "You don't have enough coins for this song.",
        { coins_required: coinsPerVariant * request.variantCount });
    }
    if (reason.includes("too_many_active_generations")) {
      return errorResponse(429, "too_many_active", "You already have songs being generated. Wait for them to finish.");
    }
    if (reason.includes("no_coin_account")) {
      return errorResponse(403, "no_coin_account", "No coin account was found for this user.");
    }
    if (reason.includes("generation_id_conflict")) {
      return errorResponse(409, "generation_id_conflict", "That request id was already used.");
    }
    console.error("[ez-music] reserve failed:", reserveError.message);
    return errorResponse(500, "reserve_failed", "Could not start the generation. You were not charged.");
  }

  const rows = (reserved ?? []) as Array<{
    entry_id: string; attempt_id: string; variant_index: number;
    coins_reserved: number; balance_after: number; already_existed: boolean;
  }>;
  const replayed = rows.length > 0 && rows[0].already_existed;

  // A replay returns the existing entries; the original request keeps running
  // (or already finished), so nothing is started a second time.
  if (!replayed) {
    const work = Promise.allSettled(rows.map((row) => runVariant(service, config, {
      userId, attemptId: row.attempt_id,
      variantIndex: row.variant_index, reservedCoins: row.coins_reserved, request,
    })));
    const inline = runInBackground(work);
    if (inline) await inline;
  }

  return jsonResponse({
    success: true,
    generation_id: request.generationId,
    replayed,
    entries: rows.map((row) => ({ entry_id: row.entry_id, variant_index: row.variant_index, status: "pending" })),
    coins_reserved: rows.reduce((sum, row) => sum + row.coins_reserved, 0),
    balance: rows[0]?.balance_after ?? null,
    poll_after_ms: 4000,
  }, 202);
}

async function handleStatus(service: SupabaseClient, userId: string, body: Record<string, unknown>): Promise<Response> {
  let query = service.from("music_entries").select(PUBLIC_ENTRY_COLUMNS).eq("user_id", userId);

  const entryIds = Array.isArray(body.entry_ids)
    ? body.entry_ids.map(String).filter((id) => UUID_PATTERN.test(id)).slice(0, 20) : [];
  if (entryIds.length > 0) {
    query = query.in("id", entryIds);
  } else if (typeof body.generation_id === "string" && UUID_PATTERN.test(body.generation_id)) {
    query = query.eq("generation_id", body.generation_id);
  } else if (typeof body.before === "string" && !Number.isNaN(Date.parse(body.before))) {
    // Inclusive on purpose: variants of one request share a created_at, so a
    // strict "<" could skip the siblings of a row that ended the previous page.
    // The client de-duplicates by id.
    query = query.lte("created_at", body.before);
  }

  const requestedLimit = Number(body.limit ?? 30);
  const limit = Math.min(Math.max(Number.isInteger(requestedLimit) ? requestedLimit : 30, 1), STATUS_LIST_LIMIT_MAX);
  const { data, error } = await query
    .order("created_at", { ascending: false }).order("variant_index", { ascending: true }).limit(limit);
  if (error) {
    console.error("[ez-music] status query failed:", error.message);
    return errorResponse(500, "query_failed", "Could not load your songs.");
  }
  return jsonResponse({ success: true, entries: (data ?? []).map((row) => publicMusicEntry(row as Record<string, unknown>)) });
}

async function loadOwnedEntry(service: SupabaseClient, userId: string, entryId: unknown) {
  if (typeof entryId !== "string" || !UUID_PATTERN.test(entryId)) return null;
  const { data } = await service.from("music_entries")
    .select("id, status, file_path, title, is_downloadable")
    .eq("id", entryId).eq("user_id", userId).maybeSingle();
  return data;
}

async function handleSignedUrl(
  service: SupabaseClient, config: MusicConfig, userId: string, body: Record<string, unknown>,
): Promise<Response> {
  const entry = await loadOwnedEntry(service, userId, body.entry_id);
  if (!entry) return errorResponse(404, "not_found", "Song not found.");
  if (entry.status !== "complete" || !entry.file_path) {
    return errorResponse(409, "not_ready", "That song isn't ready yet.");
  }
  const wantsDownload = body.download === true;
  if (wantsDownload && !entry.is_downloadable) {
    return errorResponse(403, "download_disabled", "Downloading is not available for this song.");
  }
  const safeName = `${String(entry.title).replace(/[^\w\- ]+/g, "").trim().slice(0, 60) || "song"}.mp3`;
  const { data, error } = await service.storage.from(STORAGE_BUCKET).createSignedUrl(
    entry.file_path, config.signed_url_ttl_seconds, wantsDownload ? { download: safeName } : undefined);
  if (error || !data?.signedUrl) {
    console.error("[ez-music] signed url failed:", error?.message);
    return errorResponse(500, "signed_url_failed", "Could not prepare the song for playback.");
  }
  return jsonResponse({ success: true, url: data.signedUrl, expires_in: config.signed_url_ttl_seconds });
}

async function handleSetFavorite(service: SupabaseClient, userId: string, body: Record<string, unknown>): Promise<Response> {
  const entry = await loadOwnedEntry(service, userId, body.entry_id);
  if (!entry) return errorResponse(404, "not_found", "Song not found.");
  const { error } = await service.from("music_entries")
    .update({ is_favorite: body.is_favorite === true }).eq("id", entry.id);
  if (error) return errorResponse(500, "update_failed", "Could not update the song.");
  return jsonResponse({ success: true });
}

async function handleDelete(service: SupabaseClient, userId: string, body: Record<string, unknown>): Promise<Response> {
  const entry = await loadOwnedEntry(service, userId, body.entry_id);
  if (!entry) return errorResponse(404, "not_found", "Song not found.");
  if (entry.status === "pending") {
    return errorResponse(409, "still_generating", "Wait for this song to finish before deleting it.");
  }
  if (entry.file_path) {
    const { error: removeError } = await service.storage.from(STORAGE_BUCKET).remove([entry.file_path]);
    if (removeError) {
      console.error("[ez-music] storage remove failed:", removeError.message);
      return errorResponse(500, "delete_failed", "Could not delete the song file. Try again.");
    }
  }
  const { error } = await service.from("music_entries").delete().eq("id", entry.id);
  if (error) return errorResponse(500, "delete_failed", "Could not delete the song.");
  return jsonResponse({ success: true });
}

// Multipart pass-through keeps video binary out of JSON/base64 and preserves the
// provider's documented 200 MB / 10-video capability.  The app authenticates to
// this function; the ElevenLabs key remains server-only.
async function handleVideoToMusic(form: FormData): Promise<Response> {
  const apiKey = Deno.env.get("ELEVENLABS_API_KEY");
  if (!apiKey) return errorResponse(503, "provider_unavailable", "Music generation is temporarily unavailable.");
  const videos = form.getAll("videos[]").filter((value): value is File => value instanceof File);
  if (!videos.length || videos.length > 10) return errorResponse(400, "invalid_video", "Choose 1–10 video files.");
  const totalBytes = videos.reduce((sum, video) => sum + video.size, 0);
  if (totalBytes > 200 * 1024 * 1024) return errorResponse(400, "video_too_large", "Selected videos exceed the 200 MB limit.");
  const outbound = new FormData();
  for (let index = 0; index < videos.length; index += 1) {
    const video = videos[index];
    // The iOS client has already normalized this to H.264 MP4. Recreate the
    // File with an explicit type here: Deno's FormData forwarding otherwise
    // may fall back to application/octet-stream for a multipart File. This
    // does not encode, decode, or alter a single video byte.
    const filename = `ez-music-video-${index + 1}.mp4`;
    const mp4 = new File([video], filename, { type: "video/mp4" });
    console.info(`[ez-music] forwarding video ${index + 1}: ${video.size} bytes, inbound=${video.type || "unset"}, outbound=${mp4.type}`);
    outbound.append("videos[]", mp4, filename);
  }
  const description = String(form.get("description") ?? "").trim();
  if (description) outbound.append("description", description.slice(0, PROMPT_MAX_CHARS));
  outbound.append("model_id", "music_v2_5");
  // This account uses Creator-tier output, matching the high-quality format
  // used for normal music generation.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), VIDEO_PROVIDER_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(`${ELEVENLABS_VIDEO_TO_MUSIC_URL}?output_format=${DEFAULT_FORMAT}`, {
      method: "POST", headers: { "xi-api-key": apiKey }, body: outbound, signal: controller.signal,
    });
  } catch (caught) {
    const timedOut = caught instanceof DOMException && caught.name === "AbortError";
    console.error("[ez-music] video-to-music request failed:", caught);
    return errorResponse(503, timedOut ? "video_music_timeout" : "video_music_network",
      timedOut ? "Music generation took too long. Please try a shorter video." : "Could not reach the music service. Please try again.");
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    console.error(`[ez-music] video-to-music failed ${response.status}: ${detail.slice(0, 300)}`);
    // ElevenLabs uses 422 for several unrelated input problems.  Translate
    // its detail into an action the person can take instead of always blaming
    // the file type (which made valid MP4/MOV clips look broken).
    const normalizedDetail = detail.toLowerCase();
    let message: string;
    if (response.status === 422 && /duration|600\s*(seconds|s)|10\s*(minutes|min)/.test(normalizedDetail)) {
      message = "That video is over the 10-minute limit. Choose a shorter clip.";
    } else if (response.status === 422 && /codec|encoding|container|format|unsupported.*video/.test(normalizedDetail)) {
      message = "That video’s encoding is not supported. Export it from Photos as an H.264 MP4, then try again.";
    } else if (response.status === 422 && /empty|no.*video|could not.*read|corrupt/.test(normalizedDetail)) {
      message = "That video could not be read. Export a new copy from Photos and try again.";
    } else if (response.status === 422) {
      message = "The music provider rejected this video. Try a short H.264 MP4 exported from Photos.";
    } else if (response.status === 403) {
      message = "Video music generation is not available for this music-service account.";
    } else {
      message = "Couldn’t generate music for that video. Please try again.";
    }
    return errorResponse(response.status === 422 ? 422 : 503, "video_music_failed", message);
  }
  return new Response(response.body, { status: 200, headers: {
    ...CORS_HEADERS, "Content-Type": response.headers.get("content-type") ?? "audio/mpeg",
    "X-EZ-Song-ID": response.headers.get("song-id") ?? "",
  }});
}

// ── Entry point ──────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed", "Method not allowed.");

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
      return errorResponse(401, "unauthorized", "Missing or invalid Authorization header.");
    }

    const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const { data: authData, error: authError } = await service.auth.getUser(authHeader.slice(7));
    if (authError || !authData?.user) return errorResponse(401, "unauthorized", "Please sign in again.");
    const userId = authData.user.id;

    if ((req.headers.get("content-type") ?? "").startsWith("multipart/form-data")) {
      const form = await req.formData();
      if (form.get("action") === "video_to_music") return await handleVideoToMusic(form);
      return errorResponse(400, "invalid_request", "Unknown multipart action.");
    }
    const body = await req.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || typeof body !== "object") return errorResponse(400, "invalid_request", "Invalid JSON body.");

    const config = await loadConfig(service);

    // Self-healing: refund anything this user has stuck in "reserved" before doing new work.
    const { error: reapError } = await service.rpc("reap_stale_music_attempts", {
      p_user_id: userId, p_older_than_minutes: config.stale_reservation_minutes,
    });
    if (reapError) console.error("[ez-music] stale reap failed:", reapError.message);

    switch (body.action) {
      case "config":       return jsonResponse({ success: true, config: publicConfig(config) });
      case "generate":     return await handleGenerate(service, config, userId, body);
      case "status":       return await handleStatus(service, userId, body);
      case "signed_url":   return await handleSignedUrl(service, config, userId, body);
      case "set_favorite": return await handleSetFavorite(service, userId, body);
      case "delete":       return await handleDelete(service, userId, body);
      default:             return errorResponse(400, "unknown_action", "Unknown action.");
    }
  } catch (caught) {
    console.error("[ez-music] unhandled error:", caught);
    return errorResponse(500, "internal_error", "Internal server error.");
  }
});
