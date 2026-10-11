# Optional phone verification

`PHONE_VERIFICATION_ENABLED=false` is the default when absent. Keep it false in Vercel for now. Registration, TEST fixtures, customer edits and Get Tagged do not require a code while disabled; the verification UI is hidden and the code endpoint cannot send.

After AWS SMS is configured, change the server-only Vercel variable to `PHONE_VERIFICATION_ENABLED=true` and redeploy. No further code change is required. Real customer verification requires `TOOLTAG_SMS_MODE=live`; in `test` mode only the configured test recipient can receive codes. The notification enabled toggle is independent: verification can operate even while automatic customer alerts remain disabled. Missing AWS configuration fails closed with a clear error when verification is enabled.

Get Tagged (full page/mobile and desktop modal), New Customer and phone changes in Edit Customer require a code before saving when enabled. Unchanged phone edits do not require a new code. TEST customers use the same verification process when enabled; no ownership bypass. The staff member must ask the customer for the code. Staff must not treat a code as consent to future alerts.

The customer explicitly requests a one-time transactional verification SMS. A cryptographically random six-digit code expires after ten minutes. Challenge and session/code hashes live in a private RLS-protected table; no plaintext code is persisted or logged. A random browser session secret lives only in an HttpOnly, SameSite=Strict cookie. A verified challenge is bound to that browser and exact normalized phone; changing the number requires another code. Backend registration checks the proof, independently of UI state. Retries within its ten-minute lifetime remain possible if form validation fails.

Limits enforced atomically in Postgres: one resend per phone per 60 seconds, five requests per phone/hour, twenty per network/hour, one hundred globally/hour and five code attempts. Expired challenges remain private audit records and can never verify registration. No automatic send retry; SNS opt-out is respected. Failure does not silently bypass verification. No historic/customer SMS is sent on migration or activation.

Additive migration creates only private challenge storage and service-role-only RPCs. No existing customers are marked verified and no credentials or feature flag values are committed. Toggle stays off in production until Martin opts to enable it.
