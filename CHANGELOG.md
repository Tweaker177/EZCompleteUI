# Changelog

All notable changes to EZCompleteUI are documented here. Version numbers refer
to the app/package version. Server-backed features also require their matching
Supabase Edge Function deployments and migrations.

## Unreleased

### Chat models can create songs

- Added a `create_music` tool for chat models. When you ask a model to make a
  song or instrumental, it picks the description, title, optional lyrics,
  instrumental flag and length, and the app sends that through the existing
  AI Music service. The finished song appears in the chat as an inline player
  card (play/pause, scrubber, time, **Share**) and is also saved in AI Music.
- New shared audio player (`EZMediaPlayerManager`): chat songs keep playing in
  the background and from the lock screen, and only one thing plays at a time
  (starting a chat song stops the AI Music screen's player and vice versa).
  It already has an Up Next queue in code; the queue UI comes later.
- New songs get AI cover art (about 2 coins each). When a song finishes saving, the app asks
  `ez-image` for a cover (cheapest model, `gpt-image-1-mini`, low quality)
  based on the title and lyrics, or on the style description for instrumentals.
  It shows on the chat song card, in the AI Music library list and on the lock
  screen. Pricing and coin charging happen in `ez-image`; if you're out of
  coins or offline the song simply has no cover. Existing songs are not
  back-filled. Set the `musicAutoArtworkDisabled` default to YES to turn it off.
- Text to Speech (the generator screen and History) now plays through the shared
  player too: lock-screen / Control Center controls now work for TTS clips,
  clips keep playing after you leave the screen, and clips keep their saved
  speed. The lock screen has skip back/forward 15 seconds and a scrub bar;
  previous/next appear once there is something to move to.
- Chat songs are limited to 2 minutes and one version, so a single chat song
  costs at most 60 coins at the current price. All pricing, charging, refunds
  and the limit on songs composing at once stay in the `ez-music` Edge
  Function; the chat server only passes along a validated request.
- Song cards survive closing and reopening a chat, and a song that finishes
  while another chat is open is saved into the chat that asked for it. The
  model is told when a song finished or failed, so follow-ups such as "make it
  faster" work.
- Known limit: a song still composing when the app is closed finishes on the
  server and appears in AI Music, but its card is not added to the chat.
- Server: `ez-chat` v1.7 accepts `music_tools` and returns `music_request`;
  new shared module `_shared/chat-music-tool.mjs`. Deploy both together.
- Shared the "download a finished song and keep it on the device" code between
  the AI Music screen and chat (`EZMusicLibraryManager`).

## 7.1.15 — 2026-10-17

### Highlights since 7.1.12

### Selectable thread export

- Replaced the thread **Memories** action with **Select**, allowing individual
  prompts, text responses, code blocks, and attachments to be selected for a
  focused export or action.
- Added Select All, selected-item deletion, sharing, translation, and export
  workflows for selected thread content.
- Improved document exports so they preserve each image at its original thread
  position, including repeated uses of the same attachment, and retain the
  time each item was added.
- Refined PDF layout to read more like an illustrated conversation: text and
  images share pages where possible, attachments use compact grids or aligned
  cards, and code is exported in full instead of being limited to the visible
  portion of a chat cell.
- Internal system instructions are excluded from exports. User-provided custom
  instructions and user-added system messages remain exportable.

### Image studio and gallery editing

- Expanded **Surprise Me** image editing recipes. Gallery analysis now chooses
  appropriate single-image edits or blends using two to four compatible image
  sources, rather than always attempting the same type of combination.
- Improved gallery edit resilience with streaming partial previews, bounded
  automatic recovery from transient connection failures, and a keep-awake
  state while an edit is active.
- Restored the animated teal/blue lava treatment behind the blurred source
  image and progress meter. It continues moving through the edit and fades as
  streamed image previews arrive.
- Kept long edit prompts from pushing the image under the navigation bar, and
  prevented accidental sheet pull-down dismissal while editing.

### AI Music and voice workflows

- Added the AI Music Create and Library experience, with background generation,
  coin quotes, song status polling, playback, favorites, sharing, and deletion.
- Added lyrics, a one-take **Surprise me** generator, and separate audio
  reference modes: guide a new composition by sound or retain a source clip in
  the composition.
- Added Text-to-Speech **Add Music**, which sends a completed TTS clip into
  music creation as source audio rather than treating spoken voice as a style
  sample.
- Added local `Documents/EZMusic` song/reference storage and a manifest. A
  completed streamed song is retained as WAV for future local playback, and
  invalid local candidates fall back to a fresh stream.
- Added a distinct Video Soundtrack flow. It analyzes selected video visuals,
  generates music for those visuals, and attaches the resulting soundtrack to
  the finished video; videos are no longer treated as audio references.

### Sharing, rewards, and access controls

- Added the EZCompleteUI Share Extension for incoming shared content, including
  photo workflows that can accept more than one selected image.
- Restored new-user welcome coins alongside free spins and added server-side
  installation/IP-aware bonus auditing to make repeated reward collection
  easier to detect and prevent.
- Added daily-reward IP audit data to the administrative ledger.
- Enforced purchase gating for the premium Astra and 6.1 Sol model choices,
  directing users to the store when access is required.
- Kept non-paying image generation at Medium quality or below.

### Slots and lounge refinements

- Moved the Lounge winners presentation so it no longer blocks the more
  important back navigation controls.
- Improved localized slot banner sizing so long translations scale to fit
  instead of clipping.

### AI music generation (ElevenLabs)

- Added the `ez-music` Edge Function: server-side text-to-music with prompt or
  composition-plan input, 1–3 variants, a private audio library, signed
  playback/download links, favorites and delete. All pricing, limits and coin
  accounting happen on the server; the app only sends the user's choices.
- Pricing is read from the new `music_config` table (30 coins per generated
  minute, 5-coin minimum per variant, 10 s–5 min songs) so it can be changed
  without an app update.
- Coins are reserved atomically before generation. A usable file keeps the
  charge (reduced if the track comes back clearly shorter than requested);
  failures are refunded automatically, and reservations whose background job
  died are refunded by a self-healing reaper. Re-sending the same request id
  can never charge twice.
- Generation runs in the background, so closing the app does not lose a song.
- Added `EZMusicService`, the iOS client (auth refresh, retry of dropped
  connections, polling).
- Added the **AI Music** screen (`EZMusicViewController`), opened from a new
  "AI Music" row in the history drawer. The Create tab takes a description,
  optional title, instrumental switch, length slider and 1-3 versions, with a
  live coin quote. The Library tab lists every song (including ones still
  composing and ones that failed and were refunded), with play/pause and
  progress, star, share/save through the system share sheet, and delete.
  Songs still composing are picked up again if the screen is closed and
  reopened.
- Library paging in `ez-music` now uses an inclusive cursor so variants that
  share a timestamp are never skipped between pages.
- Added the `20261012000100_add_music_generation` migration (tables, private
  `music-assets` bucket, reserve/finalize/reap RPCs).
- Usage history now labels music debits as "AI Music".

### Slots Lounge, profiles, and live hosts

- Added a **Lounge** entry point to both Brainrot Slots and EZCoin Penny Slots.
- Added opt-in public lounge profiles with a display name, profile photo, and
  optional low-volume room music.
- Added per-machine live-room presence and chat, with messages refreshed from
  the server, public account details kept private, send-rate limits, and a
  report path for moderation.
- Added a live conversational house host, **Cherry Queen**. The host uses a
  server-side GPT model with recent room context rather than canned replies,
  speaks at a globally rate-limited pace, and is shared by everyone in the
  same room.
- Added atomic per-room host-turn claims, which prevent many open clients from
  multiplying model calls or duplicate host messages.
- Clearly presents hosts as live house characters rather than player accounts,
  while keeping the room conversation natural and uncluttered.
- Added `br-slot-social` Edge Function and the `20261007000100_slot_social_rooms`
  migration for profiles, avatar storage, room presence, messages, and reports.
- Added the `20261007000200_add_live_slot_room_hosts` migration for durable
  shared host messages and host-turn rate limiting.
- Replaced new lounge profile/report system dialogs with custom Brainrot-styled
  sheets rather than generic iOS alerts or action sheets.

### Slot winnings tracker and leaderboard

- Added a server-authoritative slot winnings ledger, populated only after a
  classic or Penny Slot prize is credited through the coin ledger. Paid wins
  and free-spin payouts are both included.
- Added an app-wide **WINS** leaderboard in every slot lounge, showing each
  player’s current-day total and personal best hit, the day’s highest total
  winners, and the all-time largest individual payouts.
- Backfilled eligible historical slot credits so the leaderboard is useful on
  rollout. Credits belonging to deleted accounts are intentionally excluded
  because they cannot safely be attributed to a public profile.
- Uses a canonical UTC daily reset and privacy-safe display names; email
  addresses, account IDs, and balances are never shown to other players.
- Added the `20261007000300_add_slot_winnings_leaderboard` migration, including
  database-trigger capture and the protected leaderboard query RPC.

### Brainrot navigation

- Added consistent gold-styled in-game Back controls for Maze and Ricochet.
  They return players to the Brainrot mode picker instead of dismissing the
  entire Brainrot experience.
- Replaced the Slot library’s generic close icon with a styled **BRAINROT**
  return control. Individual slot machines continue to return to the slot
  library first.

### Free-spin finish

- Added a dedicated **Free Spins Complete** celebration when a classic Brainrot
  Slots free-spin batch reaches zero.
- The completion card shows the server-calculated batch total and uses an
  enhanced double-wave EZCoin eruption.
- `ez-slot-spin` now returns the authoritative free-spin batch total needed by
  the completion animation.

### Reward audit and abuse protection

- Added migration support for auditable free-spin grants in the usage log.
- Added a server-side, Keychain-installation-ID welcome-bonus guard so one app
  installation cannot repeatedly claim new-account welcome spins.

### Image generation reliability

- Kept progressive/partial image previews while changing the stream lifecycle
  so the SSE response opens before the upstream image request begins.
- Added heartbeat-safe streaming behavior and gallery recovery retries after a
  live-preview transport interruption.
- Replaced raw stream transport wording with a recovery-aware message that does
  not falsely report a completed or failed image job.

## 7.1.12 — 2026-10-07

### Brainrot Slots Casino

- Added a dedicated Slots game picker, with the classic Brainrot machine first,
  a new EZCoin Penny Slots machine, saved rooms, and community-game browsing.
- Added the classic **three-reel / five-payline Brainrot Slots** game with
  server-verified reels, configurable active lines and bet-per-line controls,
  max bet, a pull lever, custom symbols, an odds table, winning-line display,
  themed audio, and coin-eruption win celebrations.
- Added a progressive jackpot banner that scrolls continuously and only awards
  on the qualifying max-bet rare-symbol outcome.
- Added proper low-balance protection: the game checks the wager before
  animating a spin and opens the Coin Store in place when a top-up is needed.
- Added a custom symbol workflow using Photos, Files, gallery assets, or AI
  generation. Custom art is presented in square slot tiles and can be reset to
  the built-in symbol at any time.
- Added saved/custom/community slot-room support, including use of compatible
  Brainrot game artwork as slot themes.

### EZCoin Penny Slots

- Added a five-reel, three-row **Penny Slots** game with nine paylines and
  1/5/10/15/25 EZCoin bet-per-line options.
- Added EZCoin scatter free-spin triggers anywhere on the board: three scatters
  award five spins, four award fifteen, and five or more award twenty-five.
- Added double line payouts during Penny Slot free spins and scatter retriggers.
- Added a dedicated server-side settlement path and detailed reel-result audit
  records for paid spins, payouts, scatters, and free spins.

### Coin, ledger, and audit improvements

- Added server-authoritative slot settlement and migrations for slot usage,
  readable reel results, variable wagers, progressive jackpots, and corrected
  user-email attribution.
- Added debit and payout records to both the administrative ledger and the
  user-facing coin usage history.
- Improved ledger readability with multi-line, per-reel slot results rather
  than a truncated single-line summary.
- Improved the admin ledger data source to include manual credits/reversals as
  well as normal usage, with correct direction and email resolution.
- Added filtering improvements to the admin coin ledger, including an exclusion
  mode for feature filtering.
- Updated Coin Store handling to recognize free-spin reward responses as well
  as coin rewards.

### Custom games and Brainrot improvements

- Expanded custom-game mapping so slot themes can use available artwork from
  other Brainrot modes while falling back gracefully to default art for missing
  roles.
- Improved saved/community game download handling to prevent duplicate imports
  and reliably start the selected downloaded game.
- Refined Community and saved-game picker cards with larger game artwork,
  background-image thumbnails, simplified copy, and a more visual two-column
  presentation.
- Improved Ricochet layout behavior and associated keyboard/music settings on
  constrained device heights.
- Added more flexible game-asset generation/preparation, including image source
  selection and background handling for game artwork.

### Image studio and generation

- Added resilient GPT Image streaming with early partial preview frames,
  server-side progress, refund-aware failures, and recovery of completed images
  that were not delivered before a connection interruption.
- Improved gallery image editing and asset preparation flows, including
  background removal support for game assets.
- Added clearer image-generation error presentation and recovery behavior.

### Audio, localization, and distribution

- Improved Brainrot audio/theme handling and custom synth behavior.
- Added Russian localization resources and additional EZCoin Store language
  resources for Hindi, Japanese, Portuguese, Russian, and Thai.
- Added Photo Library usage copy for custom slot symbol selection.
- Updated AltStore source metadata with screenshots, Fediverse account metadata,
  and release information.

### Compatibility

- Requires iOS 15.0 or later.
- Includes IPA and rootless arm64 DEB packaging workflows.

## 7.1.10 — 2026-10-01

See the 7.1.10 GitHub release for the previous release notes.
