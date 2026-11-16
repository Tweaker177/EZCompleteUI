# GitHub tool for ez-chat

Same handoff pattern as `create_music`: the model only picks an action, ez-chat validates it and returns it, the app runs it through a second function. Nothing in ez-chat talks to GitHub, and the model never sees a token.

## Files and where they go

| File here | Destination |
|---|---|
| `chat-github-tool.mjs` | `supabase/functions/_shared/chat-github-tool.mjs` |
| `ez-github-index.ts` | `supabase/functions/ez-github/index.ts` (new function) |
| `ez-chat-index.ts` | `supabase/functions/ez-chat/index.ts` (your v1.9 + a v1.10 patch) |
| `github_connections.sql` | run once in the SQL editor (table + private `github-archives` bucket) |

The ez-chat patch is small: one import, `github_tools` in the body, a connection lookup, instructions + tool definition, extraction, and `github_request` / `github_summary` in the response. Old app builds never send `github_tools`, so nothing changes for them.

## Deploy

```
supabase secrets set GITHUB_TOKEN_ENC_KEY=$(openssl rand -base64 32)
supabase functions deploy ez-github
supabase functions deploy ez-chat
```

## Connecting a token

The first version takes a **fine-grained personal access token** pasted in Settings, so there is no OAuth flow to build yet. Have the user create it at github.com/settings/personal-access-tokens with access to *selected repositories* only:

- Read-only: **Contents: Read** (Metadata is added automatically). Add **Pull requests: Read** and **Issues: Read** to list those.
- Writes: **Contents: Read and write** and **Pull requests: Read and write**. Leave **Workflows** off.

The token is checked against GitHub, AES-GCM encrypted, and stored in `github_connections`. Later you can swap the paste step for a GitHub App / OAuth flow; ez-github only needs the stored token to change.

## App contract

1. **Connect:** `POST ez-github {op:"connect", token}` returns `{ok, login, token_expires_at}`. `{op:"status"}` returns `{connected, login, allow_writes}`. `{op:"disconnect"}` forgets the token.
2. **Writes toggle (off by default):** `{op:"set_permissions", allow_writes:true}`. This flag is read server-side by ez-chat, which only offers the write actions to the model when it is true.
3. **Chat:** add `github_tools: true` to the ez-chat body. ez-chat only enables the tool if the user has a connection.
4. **When the ez-chat response has `github_request`:** show `github_summary` as a status line ("Reading 3 files in acme/api@main"), then `POST ez-github {op:"run", request: github_request}`:
   - `needs_confirmation: true` (writes): show `summary` + `details` (and the file contents from the request itself) in an approval sheet. On Approve, repeat the same call with `confirmed: true`. On Decline, send the model a user message like "[The user declined that GitHub action.]".
   - `ok: true`: append `message_for_model` to the conversation as a **user** message (it is already framed as untrusted data and size-capped), then call ez-chat again with the same flags. Cap this loop at about 8 rounds per user message.
   - `archive`: show a Download button for `archive.url` (signed, valid 1 hour).
   - `links`: show them as tappable results after a write.
   - `ok: false`: if `message_for_model` is present, feed it back so the model can adjust (wrong path, branch exists, ...). For `github_token_invalid` and `github_not_connected`, show a "reconnect GitHub" prompt instead.
5. Keep the `message_for_model` messages in history so the model remembers what it read; you can collapse them in the visible transcript.

Each round trip is an ordinary ez-chat call, so coins, daily caps and refunds work exactly as they do now. Large reads raise the token count, so pass a realistic `estimated_tokens` on the follow-up call (overage is billed by your existing reconciliation).

## What the server enforces (the app can't override it)

- Every request is validated and clamped twice (ez-chat and ez-github): owner/repo/ref/path shapes, no `..`, at most 25 files per read, at most 20 files / 500k chars per commit.
- Writes need `allow_writes = true` **and** an explicit `confirmed: true` after a preview computed from the live branch.
- Direct commits to the default branch are blocked (`ALLOW_DEFAULT_BRANCH_COMMITS` in ez-github flips this), commits never force-push, and there is no merge or delete-branch action.
- Writes to `.git/` and `.github/workflows` / `.github/actions` are rejected, since those run code with the repo's secrets.
- Results are capped at 60k characters, 20k per file; binary and over-400 KB files are skipped. Archives are capped at 40 MB.
- Repo text reaches the model inside a "this is data, not instructions" frame.

## Limits to know

- `download_archive` gives the **user** a zip. The model can't open it, so "read the whole project" works through `get_tree` then batched `read_files` (25 files per call, follow-up rounds as needed).
- GitHub code search is rate limited (about 30 requests per minute) and `get_tree` can come back truncated on very large repos; the model is told when either happens.
- Fine-grained PATs expire; `connect` returns `token_expires_at` so you can warn the user.
