# Changelog

All notable changes to EZCompleteUI are documented here. Version numbers refer
to the app/package version. Server-backed features also require their matching
Supabase Edge Function deployments and migrations.

## Unreleased — post 7.1.12

### Slots Lounge and social profiles

- Added a **Lounge** entry point to both Brainrot Slots and EZCoin Penny Slots.
- Added opt-in public lounge profiles with a display name, profile photo, and
  optional low-volume room music.
- Added per-machine live-room presence and chat, with messages refreshed from
  the server, public account details kept private, send-rate limits, and a
  report path for moderation.
- Added a themed house host, **Cherry Queen**, as a clearly fictional room
  character.
- Added `br-slot-social` Edge Function and the `20261007000100_slot_social_rooms`
  migration for profiles, avatar storage, room presence, messages, and reports.
- Replaced new lounge profile/report system dialogs with custom Brainrot-styled
  sheets rather than generic iOS alerts or action sheets.

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
