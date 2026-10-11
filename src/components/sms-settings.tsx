"use client";
import { useActionState } from "react";
import { saveSmsSettings, sendTestSms } from "@/app/sms-actions";
export type SmsSettingsInfo = { enabled?: boolean; region?: string; origination_number?: string; test_phone?: string; credentials_saved?: boolean; last_test_result?: string; logs?: { event: string; status: string; reason?: string; provider_id?: string }[] };
export function SmsSettings({ info, mode, envConfigured, envRegion, envOrigin, envTestPhone, encryptionReady }: { info: SmsSettingsInfo; mode: string; envConfigured: boolean; envRegion: string; envOrigin: string; envTestPhone: string; encryptionReady: boolean }) {
  const [saved, save, pending] = useActionState(saveSmsSettings, {}), [test, send, sending] = useActionState(sendTestSms, {});
  return <section className="panel"><h2>SMS · AWS SNS</h2><p>Server mode: {mode}. Customer SMS requires explicit opt-in. Enabling sends only new notifications; old notifications are never replayed.</p>
    <p>Credentials: {envConfigured ? "Configured in server environment (takes precedence)" : info.credentials_saved ? "Saved encrypted · never displayed" : "Not configured"}.</p>
    {!encryptionReady && <p className="notice">To save keys here, configure TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY in Vercel. You can also put the AWS keys directly in Vercel.</p>}
    <form action={save} className="formgrid">
      <label>AWS Access Key ID<input name="access_key" type="password" autoComplete="off" placeholder="Leave blank to keep existing keys" /></label>
      <label>AWS Secret Access Key<input name="secret_key" type="password" autoComplete="new-password" placeholder="Never shown after saving" /></label>
      <label>AWS Session Token (temporary credentials only)<input name="session_token" type="password" autoComplete="off" /></label>
      <label>AWS region<input name="region" defaultValue={info.region || envRegion} placeholder="us-west-2" /></label>
      <label>Origination number<input name="origin" type="tel" defaultValue={info.origination_number || envOrigin} placeholder="+1…" /></label>
      <label>Test recipient · your phone only<input name="test_phone" type="tel" defaultValue={info.test_phone || envTestPhone} placeholder="+1…" /></label>
      <label className="checkbox wide"><input name="enabled" type="checkbox" defaultChecked={info.enabled} />Enable customer SMS</label>
      <button disabled={pending}>Save SMS settings</button>
      {saved.error && <p className="notice error wide" role="alert">{saved.error}</p>}{saved.message && <p className="notice success wide" role="status">{saved.message}</p>}
    </form>
    <form action={send} className="stack"><label className="checkbox"><input type="checkbox" name="test_consent" required />The configured test number is mine. I consent to receiving this test SMS.</label><button disabled={sending}>Send test SMS</button>
      {test.error && <p className="notice error" role="alert">{test.error}</p>}{test.message && <p className="notice success" role="status">{test.message}</p>}
    </form>
    {info.last_test_result && <p>Last test: {info.last_test_result}</p>}
    <details><summary>SMS delivery log</summary>{!info.logs?.length && <p>No SMS delivery events.</p>}{info.logs?.map((log,i) => <p key={i}>{log.event} · {log.status} · {log.reason || log.provider_id || ""}</p>)}</details>
  </section>;
}
