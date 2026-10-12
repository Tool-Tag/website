import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { renderSms, resolveSmsConfig, SmsFailure, SnsSmsTransport } from "./sms";
export function smsAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  return url && key ? createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } }) : null;
}
export async function dispatchSms(db: SupabaseClient) {
  const summary = { sent: 0, skipped: 0, failed: 0 };
  try {
    const { data: stored, error } = await db.rpc("sms_runtime_config");
    if (error || !stored) return summary; // Deployment without the additive migration remains safe.
    const config = resolveSmsConfig(stored);
    if (!config?.enabled || !["live","test"].includes(process.env.TOOLTAG_SMS_MODE ?? "")) return summary;
    for (let i = 0; i < 10; i++) {
      const { data: event, error: claimError } = await db.rpc("claim_sms");
      if (claimError || !event) break;
      let status: "Sent" | "Failed" | "Unknown" | "Skipped" = "Skipped", reason: string | null = "SMS_NOT_CONFIGURED", provider: string | null = null;
      try {
        if (config && config.enabled) {
          if (process.env.TOOLTAG_SMS_MODE !== "live" && !(process.env.TOOLTAG_SMS_MODE === "test" && event.test_customer === true)) reason = "SMS_NOT_LIVE";
          else {
            const context = await db.rpc("sms_message_context", {p_notification:event.id});
            if(context.error || !context.data) throw new SmsFailure("SMS_CONTEXT_UNAVAILABLE", "Skipped");
            provider = await new SnsSmsTransport(config).send(event.phone, renderSms(event.event, context.data, process.env.TOOLTAG_PUBLIC_URL ?? ""), event.test_customer === true);
            status = "Sent"; reason = null;
          }
        }
      } catch (failure) {
        status = failure instanceof SmsFailure ? failure.status : "Failed";
        reason = failure instanceof SmsFailure ? failure.code : "SMS_RENDER_FAILED";
      }
      const result = await db.rpc("finish_sms", { p_id: event.id, p_claim: event.claim, p_status: status, p_provider: provider, p_reason: reason });
      console.info("SMS_DELIVERY", { id: event.id, event: event.event, status, reason });
      if (result.error || !result.data) { console.error("SMS_RESULT_NOT_RECORDED", { id: event.id, provider }); break; }
      if (status === "Sent") summary.sent++; else if (status === "Skipped") summary.skipped++; else summary.failed++;
    }
  } catch { console.error("SMS_DISPATCH_UNAVAILABLE"); }
  return summary;
}
