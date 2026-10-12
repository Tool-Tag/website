"use server";
import { smsGrantAllowed } from "@/lib/integrations/sms-policy";
import { revalidatePath } from "next/cache";
import { context } from "@/lib/domain/context";
import { supabase } from "@/lib/supabase/server";
import { smsAdminClient } from "@/lib/integrations/sms-dispatch";
import { encryptSmsCredentials, normalizeSmsPhone, resolveSmsConfig, SmsFailure, smsNetworkAllowed, SnsSmsTransport } from "@/lib/integrations/sms";
export type SmsActionState = { error?: string; message?: string };
export async function saveSmsSettings(_state: SmsActionState, form: FormData): Promise<SmsActionState> {
  const { db, access } = await context(); if (!access.owner) return { error: "Admin access required." };
  const enabled = form.get("enabled") === "on";
  const region = String(form.get("region") ?? "").trim(), origin = String(form.get("origin") ?? "").trim(), testPhone = String(form.get("test_phone") ?? "").trim();
  if (region && !/^[a-z]{2}(-[a-z]+)+-\d+$/.test(region)) return { error: "Enter an AWS region, for example us-west-2." };
  if ((origin && normalizeSmsPhone(origin) !== origin) || (testPhone && normalizeSmsPhone(testPhone) !== testPhone)) return { error: "Use international phone format, such as +18015550100." };
  const accessKeyId = String(form.get("access_key") ?? "").trim(), secretAccessKey = String(form.get("secret_key") ?? "").trim(), sessionToken = String(form.get("session_token") ?? "").trim();
  if (Boolean(accessKeyId) !== Boolean(secretAccessKey) || (sessionToken && !accessKeyId)) return { error: "Provide both AWS keys when replacing credentials." };
  let encrypted: string | null = null;
  try {
    if (accessKeyId) encrypted = encryptSmsCredentials({ accessKeyId, secretAccessKey, sessionToken: sessionToken || undefined });
  } catch { return { error: "Configure TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY in Vercel before saving AWS keys here. Alternatively configure the AWS keys directly in Vercel." }; }
  if (enabled) {
    if (!["test", "live"].includes(process.env.TOOLTAG_SMS_MODE ?? "") || !smsNetworkAllowed()) return { error: "SMS activation requires TOOLTAG_SMS_MODE=test or live in production. Test mode sends automatic alerts only for TEST- customers to the configured test recipient." };
    const admin = smsAdminClient(); if (!admin) return { error: "The server SMS integration is not configured." };
    const current = await admin.rpc("sms_runtime_config");
    try {
      if (current.error || !resolveSmsConfig({ ...current.data, region, origination_number: origin, encrypted_credentials: encrypted || current.data?.encrypted_credentials })) return { error: "Configure AWS keys, region and origination number before enabling SMS." };
    } catch { return { error: "Stored SMS credentials could not be read. Replace them or check the server encryption key." }; }
  }
  const { error } = await db.rpc("save_sms_settings", { p_config: { enabled, region, origination_number: origin, test_phone: testPhone }, p_encrypted: encrypted });
  if (error) return { error: "SMS settings could not be saved. Check that the SMS migration is applied." };
  revalidatePath("/app/settings"); return { message: enabled ? "SMS enabled for new, consented notifications only." : "Settings saved. Customer SMS is disabled." };
}
export async function sendTestSms(_state: SmsActionState, form: FormData): Promise<SmsActionState> {
  const { db, access } = await context(); if (!access.owner) return { error: "Admin access required." };
  if (form.get("test_consent") !== "on") return { error: "Confirm that the configured test number is yours and you consent to this SMS." };
  const admin = smsAdminClient(); if (!admin || !smsNetworkAllowed()) return { error: "Configure SMS credentials and TOOLTAG_SMS_MODE=test or live in Vercel first." };
  try {
    const result = await admin.rpc("sms_runtime_config"); if (result.error) return { error: "SMS database setup is pending." };
    const config = resolveSmsConfig(result.data ?? {}); if (!config || normalizeSmsPhone(config.testPhone) !== config.testPhone) return { error: "Save AWS credentials, region, origination number and an international-format test recipient first." };
    const reserved = await db.rpc("reserve_sms_test"); if (reserved.error || !reserved.data) return { error: "Wait 90 seconds before sending another test SMS." };
    let outcome: string;
    try { outcome = `SNS accepted test: ${await new SnsSmsTransport(config).send(config.testPhone, "ToolTag: Your SMS test is working. No customer notification was sent. Reply STOP to opt out.", true)}`; }
    catch (failure) { outcome = failure instanceof SmsFailure ? failure.code : "SMS_TEST_FAILED"; await admin.rpc("finish_sms_test", { p_result: outcome }); return { error: `Test SMS was not confirmed (${outcome}). Check AWS permissions, sandbox verification and origination registration.` }; }
    const logged = await admin.rpc("finish_sms_test", { p_result: outcome });
    revalidatePath("/app/settings"); return { message: logged.error ? "SNS accepted the test; delivery log could not be updated. Do not resend without checking AWS." : "SNS accepted the test SMS. Check the configured test phone; acceptance does not guarantee handset delivery." };
  } catch { return { error: "SMS test could not be started. Check server configuration." }; }
}
export async function saveSmsConsent(_state: SmsActionState, form: FormData): Promise<SmsActionState> {
  const db = await supabase(), granted = form.get("sms_opt_in") === "on";
  const phone = normalizeSmsPhone(String(form.get("sms_phone") ?? ""));
  if (form.get("accept_sms") === "yes" && !granted) return {error:"Check the SMS consent checkbox before accepting."};
  if (granted && form.get("sms_policy_accepted") !== "on") return {error:"Accept Terms of Service and Privacy Policy to enable SMS."};
  if (granted && !phone) return { error: "Enter a valid mobile number with country code." };
  if(!(await smsGrantAllowed(db,String(form.get("token") || ""),String(form.get("scope") || ""),phone || "",granted))) return {error:"New SMS subscriptions require published Privacy Policy and Terms links."};
  const { error } = await db.rpc("set_sms_consent", { p_token: String(form.get("token") ?? ""), p_scope: String(form.get("scope") ?? ""), p_phone: phone ?? "", p_granted: granted });
  if (error) return { error: "SMS preferences could not be saved. Check your secure link and try again." };
  if(form.get("scope") === "status") revalidatePath(`/status/${String(form.get("token"))}`);
  return { message: granted ? "SMS consent saved for this quote/job." : "SMS consent withdrawn for this number." };
}
