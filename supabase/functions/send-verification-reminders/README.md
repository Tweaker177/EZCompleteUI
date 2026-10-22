# Verification reminder campaign

This admin-only Edge Function finds unconfirmed accounts, generates a fresh
Supabase confirmation link for each, and sends the reminder through Resend.
It honors `subscriptions.marketing_opt_in`, waits 24 hours by default, and
records each accepted delivery in `verification_reminder_deliveries` so a later
run does not send another reminder. Failed sends retry after an hour, up to
three attempts. Recipients are always selected oldest signup first.

The campaign has an independent daily and monthly budget, so it cannot exhaust
the account's Resend allocation and block password resets or other
transactional messages. Every claimed attempt counts toward the campaign budget
(including a failed attempt), which is the safe choice when Resend may already
have accepted a message before a later database update fails.

Apply the migration and deploy the function, then set these secrets:

```sh
supabase db push
supabase functions deploy send-verification-reminders --no-verify-jwt
```

Then set the secrets:

```sh
supabase secrets set REMINDER_CRON_SECRET='<long random value>'
supabase secrets set RESEND_API_KEY='<resend key>'
supabase secrets set VERIFICATION_REMINDER_FROM='EZComplete <support@ezcompleteai.com>'
supabase secrets set VERIFICATION_REMINDER_DAILY_BUDGET=20
supabase secrets set VERIFICATION_REMINDER_MONTHLY_BUDGET=500
```

`VERIFICATION_REMINDER_FROM` is optional if that default sender is verified in
Resend. `EMAIL_CONFIRMATION_REDIRECT_URL` is optional; its default matches the
existing app signup redirect. The defaults reserve 80 of Resend Free's 100
daily emails and 2,500 of its 3,000 monthly emails for transactional traffic.
Set either budget to `0` to pause the campaign. Configure these below the
capacity you want to reserve for transactional mail; they apply even on paid
plans, which helps prevent accidental campaign spend.

Preview first—the default is dry-run and returns the candidate list:

```sh
curl --fail-with-body -X POST 'https://<project-ref>.supabase.co/functions/v1/send-verification-reminders' \
  -H 'Content-Type: application/json' \
  -H 'x-reminder-secret: <REMINDER_CRON_SECRET>' \
  --data '{"dry_run":true,"minimum_age_hours":24,"limit":100}'
```

After reviewing the response, change `dry_run` to `false` to send. Schedule the
same POST only after the dry run looks right. The function limits one invocation
to 500 accounts.
