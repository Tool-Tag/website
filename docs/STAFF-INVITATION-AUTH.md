# Staff invitations and password recovery

The Owner's Users and Roles screen grants ToolTag access separately from password setup. `Active` is the staff authorization flag; it does not mean the recipient finished onboarding.

## Production Auth configuration

Supabase project boft-core previously had Site URL `http://localhost:3000` and no redirect URLs. With Martin's explicit approval, URL Configuration was saved and reloaded to verify:

- Site URL: `https://tooltag.martinlab.studio`
- Redirect URL: `https://tooltag.martinlab.studio/auth/callback`
- Redirect URL: `https://tooltag.martinlab.studio/auth/callback?next=/auth/reset`

This was an Auth configuration change only: no migrations, role changes, users deleted/recreated or passwords set. The default invitation template uses `{{ .ConfirmationURL }}` and was left unchanged. Auth is shared at project level; Site URL is the default for all clients without an allowed explicit redirect. Other apps must provide their own approved redirect rather than depend on ToolTag's default.

The app's existing `TOOLTAG_PUBLIC_URL` must be the production HTTPS origin. Staff invitation/recovery actions now fail with a configuration message if it is missing or points to localhost in production, instead of silently choosing localhost or an unapproved deployment hostname. Auth allowlisting is independent of Vercel environment configuration. Old emails containing localhost are not rewritten by a configuration change, and already consumed invitation links cannot be reused.

## App correction

Default admin invitation emails can return `#access_token=...&refresh_token=...&type=invite`, which is not sent to a server Route Handler. `/auth/callback` previously handled only `?code=...`, sending invitations back to login without persisting the session.

- Existing PKCE code exchange stays server-side.
- Fragment callbacks redirect to `/auth/complete` without specifying a fragment, preserving the incoming fragment per browser redirect behavior.
- The client removes the fragment from history immediately, accepts only invite/recovery flows, uses the publishable client to establish SSR cookies and validates the user with Auth before opening `/auth/reset`.
- Malformed, expired and rejected links show a generic English error without logging/rendering credentials or falling back to an unrelated signed-in account.
- `/auth/reset` identifies the account whose password will be changed. The recipient enters their own password; staff never sets it.
- Owner-initiated recovery uses the private non-persisting Auth client so the link is not tied to a PKCE verifier in the Owner's browser cookies. Owner authorization and the audit entry remain intact.
- Public callback/continuation entry is exempt from the *prior session* timeout gate. Password setup and all protected workspace/driver routes keep their existing authentication/session/permission checks.

## Remaining production verification

This code requires review/merge/deploy before it fixes the app callback. No real invitation/recovery emails are sent during local checks. After deployment, the Owner should request a fresh recovery email for the existing invited user, then the recipient opens it on their own device, chooses a password and signs in. Never share the email link or password in chat. Do not recreate the user or alter roles to repair an email redirect.

References: Supabase Auth Redirect URLs, SSR Advanced Guide, inviteUserByEmail API.

Local validation passed: typecheck, lint (zero warnings), 218 tests and production build with non-secret placeholder public configuration. Browser verification used only a fake invalid fragment: callback-to-continuation preserved it, then history was cleared and a generic error appeared without reflecting the marker. No real invitation/password flow was executed.
