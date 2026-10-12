// password-reset-redirect/index.ts
// EZCompleteUI — Supabase Edge Function
//
// Purpose:
//   Acts as the intermediate landing page for the Supabase password reset email
//   flow. Supabase verifies the token from the email link, then redirects to this
//   URL with session tokens in the URL fragment (#access_token=...&refresh_token=...).
//   Because URL fragments are never sent to the server, this function returns a
//   static HTML page whose JavaScript extracts the tokens client-side and routes
//   the user back into EZCompleteUI via the ezcomplete:// custom URL scheme.
//
//   LiveContainer support: since ezcomplete:// is registered in the guest app's
//   Info.plist but not in iOS's system-level URL scheme registry (LiveContainer
//   is the installed app, not EZCompleteUI), the native scheme open will fail
//   silently. The page falls back to livecontainer://open-url which passes the
//   URL to whatever guest app is currently running in LiveContainer. Variants
//   for livecontainer2:// and livecontainer3:// are also provided for users with
//   multiple LiveContainer instances.
//
// Deploy with:
//   supabase functions deploy password-reset-redirect
//
// Required Supabase dashboard configuration:
//   Authentication → URL Configuration → Redirect URLs
//   Add: https://<your-project-ref>.supabase.co/functions/v1/password-reset-redirect

Deno.serve((_req: Request): Response => {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>EZCompleteUI — Account Link</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
      background: #f2f2f7;
      min-height: 100dvh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 24px;
    }

    .card {
      background: white;
      border-radius: 20px;
      padding: 36px 28px;
      max-width: 400px;
      width: 100%;
      text-align: center;
      box-shadow: 0 4px 24px rgba(0, 0, 0, 0.08);
    }

    .app-title {
      font-size: 26px;
      font-weight: 700;
      color: #1c1c1e;
      margin-bottom: 8px;
    }

    .status-message {
      font-size: 15px;
      color: #3c3c43;
      line-height: 1.5;
      margin-bottom: 28px;
    }

    .btn {
      display: block;
      width: 100%;
      padding: 15px 20px;
      border-radius: 14px;
      font-size: 16px;
      font-weight: 600;
      cursor: pointer;
      text-decoration: none;
      border: none;
      margin-bottom: 10px;
      transition: opacity 0.15s ease;
    }
    .btn:active { opacity: 0.7; }
    .btn:last-of-type { margin-bottom: 0; }

    .btn-primary   { background: #007AFF; color: white; }
    .btn-secondary { background: #f2f2f7; color: #007AFF; }

    .divider {
      font-size: 12px;
      color: #aeaeb2;
      margin: 16px 0 12px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }

    .footnote {
      font-size: 12px;
      color: #aeaeb2;
      margin-top: 20px;
      line-height: 1.4;
    }

    .error-text { color: #ff3b30; }

    /* Buttons start hidden; JS shows only what's needed */
    .btn { display: none; }
    .divider { display: none; }
  </style>
</head>
<body>
  <div class="card">
    <p class="app-title">EZCompleteUI</p>
    <p class="status-message" id="statusMessage">
      Opening EZCompleteUI&hellip;
    </p>

    <a id="btnNative" class="btn btn-primary">Open in EZCompleteUI</a>

    <p class="divider" id="lcDivider">Installed in LiveContainer?</p>
    <a id="btnLC1" class="btn btn-secondary">LiveContainer</a>
    <a id="btnLC2" class="btn btn-secondary">LiveContainer 2</a>
    <a id="btnLC3" class="btn btn-secondary">LiveContainer 3</a>

    <p class="footnote" id="footnote"></p>
  </div>

  <script>
    // ── Token extraction ──────────────────────────────────────────────────────
    // Supabase appends tokens to the URL fragment (#key=value&key=value).
    // Fragments are never sent to the server — we must read them here, client-side.
    function parseFragment() {
      const fragment = window.location.hash.substring(1); // strip leading '#'
      const params = {};
      fragment.split('&').forEach(function(pair) {
        const separatorIndex = pair.indexOf('=');
        if (separatorIndex === -1) return;
        const key   = decodeURIComponent(pair.substring(0, separatorIndex));
        const value = decodeURIComponent(pair.substring(separatorIndex + 1));
        params[key] = value;
      });
      return params;
    }

    const params       = parseFragment();
    const accessToken  = params['access_token'];
    const refreshToken = params['refresh_token'];
    const callbackType = params['type'] || 'recovery';
    const errorCode    = params['error'] || params['error_code'];
    const errorDesc    = params['error_description'];

    const statusMessage = document.getElementById('statusMessage');
    const footnote      = document.getElementById('footnote');
    const lcDivider     = document.getElementById('lcDivider');
    const btnNative     = document.getElementById('btnNative');
    const btnLC1        = document.getElementById('btnLC1');
    const btnLC2        = document.getElementById('btnLC2');
    const btnLC3        = document.getElementById('btnLC3');

    // ── Error state ───────────────────────────────────────────────────────────
    if (errorCode) {
      statusMessage.innerHTML =
        '<span class="error-text">This account link has expired or has already been used.<br>' +
        'Please request a new one from EZCompleteUI.</span>';
      footnote.textContent = errorDesc || '';
      // No buttons to show — user must go back to the app
    }

    // ── Missing tokens ────────────────────────────────────────────────────────
    else if (!accessToken || !refreshToken) {
      statusMessage.innerHTML =
        '<span class="error-text">This link appears to be invalid.<br>' +
        'Please request a new account email from EZCompleteUI.</span>';
    }

    // ── Valid tokens — build deep links ───────────────────────────────────────
    else {
      // Tokens go as query parameters (not fragment) on the custom scheme URL.
      // Custom URL schemes have inconsistent fragment support across iOS versions,
      // but query parameters are always parsed correctly.
      var deepLink =
        'ezcomplete://' + (callbackType === 'recovery' ? 'password-reset' : 'auth') +
        '?access_token='  + encodeURIComponent(accessToken) +
        '&refresh_token=' + encodeURIComponent(refreshToken) +
        '&type=' + encodeURIComponent(callbackType);

      // LiveContainer's open-url action passes a URL to the currently running
      // guest app. The URL parameter must be standard base64-encoded.
      // This works when EZCompleteUI is active (or backgrounded) inside LiveContainer.
      var base64DeepLink = btoa(deepLink);
      var lcOpenUrl      = '?url=' + base64DeepLink;

      // Wire up all buttons
      btnNative.href = deepLink;
      btnLC1.href    = 'livecontainer://open-url'  + lcOpenUrl;
      btnLC2.href    = 'livecontainer2://open-url' + lcOpenUrl;
      btnLC3.href    = 'livecontainer3://open-url' + lcOpenUrl;

      // Show all buttons immediately so they're available if the auto-open
      // fails (native scheme not registered = LiveContainer install)
      btnNative.style.display  = 'block';
      lcDivider.style.display  = 'block';
      btnLC1.style.display     = 'block';
      btnLC2.style.display     = 'block';
      btnLC3.style.display     = 'block';

      // Attempt automatic open via the native scheme. If EZCompleteUI is
      // installed natively, iOS opens it immediately and this page is abandoned.
      // If it's in LiveContainer (scheme not registered system-wide), nothing
      // happens and the user sees the buttons below.
      window.location.href = deepLink;

      // After a short wait, update the message to prompt manual action.
      // If the native open worked, the user is already in the app and never
      // sees this updated text.
      setTimeout(function() {
        statusMessage.textContent =
          'Tap "Open in EZCompleteUI" if the app is installed natively, ' +
          'or use the matching LiveContainer button if running inside LiveContainer.';
        footnote.textContent =
          'This account link is valid for 60 minutes from when you requested it.';
      }, 900);
    }
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      // Prevent the page from being cached — tokens must be freshly read each time
      'Cache-Control': 'no-store',
    },
  });
});
