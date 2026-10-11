import { CheckIfPhoneNumberIsOptedOutCommand, PublishCommand, SNSClient } from "@aws-sdk/client-sns";
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
export type SmsCredentials = { accessKeyId: string; secretAccessKey: string; sessionToken?: string };
export type SmsConfig = SmsCredentials & { region: string; originationNumber: string; testPhone: string; enabled: boolean };
type Env = Record<string, string | undefined>;
export function normalizeSmsPhone(input: string): string | null {
  const trimmed = input.trim();
  if (!/^[+()\d\s.-]+$/.test(trimmed)) return null;
  const digits = trimmed.replace(/\D/g, "");
  const number = trimmed.startsWith("+") ? `+${digits}` : digits.length === 10 ? `+1${digits}` : digits.length === 11 && digits.startsWith("1") ? `+${digits}` : "";
  return /^\+[1-9]\d{7,14}$/.test(number) ? number : null;
}
function encryptionKey(env: Env) {
  const key = Buffer.from(env.TOOLTAG_SMS_SETTINGS_ENCRYPTION_KEY ?? "", "base64");
  if (key.length !== 32) throw new Error("SMS_SETTINGS_ENCRYPTION_KEY_REQUIRED");
  return key;
}
export function encryptSmsCredentials(value: SmsCredentials, env: Env = process.env) {
  const iv = randomBytes(12), cipher = createCipheriv("aes-256-gcm", encryptionKey(env), iv);
  const data = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
  return [iv, cipher.getAuthTag(), data].map(part => part.toString("base64url")).join(".");
}
export function decryptSmsCredentials(value: string, env: Env = process.env): SmsCredentials {
  const [iv, tag, data] = value.split(".").map(part => Buffer.from(part, "base64url"));
  if (!iv || !tag || !data) throw new Error("SMS_CREDENTIALS_INVALID");
  const decipher = createDecipheriv("aes-256-gcm", encryptionKey(env), iv); decipher.setAuthTag(tag);
  const decoded = JSON.parse(Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8"));
  if (!decoded.accessKeyId || !decoded.secretAccessKey) throw new Error("SMS_CREDENTIALS_INVALID");
  return decoded;
}
export type SmsStoredConfig = { encrypted_credentials?: string; region?: string; origination_number?: string; test_phone?: string; enabled?: boolean };
export function resolveSmsConfig(stored: SmsStoredConfig, env: Env = process.env): SmsConfig | null {
  let credentials: SmsCredentials | undefined;
  if (env.AWS_ACCESS_KEY_ID || env.AWS_SECRET_ACCESS_KEY) {
    if (!env.AWS_ACCESS_KEY_ID || !env.AWS_SECRET_ACCESS_KEY) return null;
    credentials = { accessKeyId: env.AWS_ACCESS_KEY_ID, secretAccessKey: env.AWS_SECRET_ACCESS_KEY, sessionToken: env.AWS_SESSION_TOKEN };
  } else if (stored.encrypted_credentials) credentials = decryptSmsCredentials(stored.encrypted_credentials, env);
  const region = env.AWS_REGION || stored.region || "";
  const originationNumber = env.TOOLTAG_SMS_ORIGINATION_NUMBER || stored.origination_number || "";
  if (!credentials || !/^[a-z]{2}(-[a-z]+)+-\d+$/.test(region) || !/^\+[1-9]\d{7,14}$/.test(originationNumber)) return null;
  return { ...credentials, region, originationNumber, testPhone: env.TOOLTAG_SMS_TEST_PHONE || stored.test_phone || "", enabled: Boolean(stored.enabled) };
}
export function smsNetworkAllowed(env: Env = process.env) {
  return ["test", "live"].includes(env.TOOLTAG_SMS_MODE ?? "preview") && (env.VERCEL_ENV === "production" || env.TOOLTAG_SMS_ALLOW_LOCAL_LIVE === "true");
}
export class SmsFailure extends Error {
  constructor(public code: string, public status: "Failed" | "Unknown" | "Skipped") { super(code); }
}
interface SmsSender {
  send(command: CheckIfPhoneNumberIsOptedOutCommand | PublishCommand, options?: { abortSignal: AbortSignal }): Promise<{ isOptedOut?: boolean; MessageId?: string }>;
}
export class SnsSmsTransport {
  private client: SmsSender;
  constructor(private config: SmsConfig, private env: Env = process.env, client?: SmsSender) {
    this.client = client ?? new SNSClient({ region: config.region, credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey, sessionToken: config.sessionToken }, maxAttempts: 1 });
  }
  async send(phone: string, message: string, test = false, verification = false) {
    if (!smsNetworkAllowed(this.env)) throw new SmsFailure("SMS_NETWORK_DISABLED", "Skipped");
    if ((verification && this.env.PHONE_VERIFICATION_ENABLED !== "true") || (!test && ((!verification && !this.config.enabled) || this.env.TOOLTAG_SMS_MODE !== "live")) || (test && phone !== this.config.testPhone)) throw new SmsFailure("SMS_MODE_BLOCKED", "Skipped");
    if (normalizeSmsPhone(phone) !== phone || !message.trim() || message.length > 1000) throw new SmsFailure("SMS_INPUT_INVALID", "Failed");
    let optedOut: boolean | undefined;
    try { optedOut = (await this.client.send(new CheckIfPhoneNumberIsOptedOutCommand({ phoneNumber: phone }), { abortSignal: AbortSignal.timeout(8000) })).isOptedOut; }
    catch { throw new SmsFailure("SMS_OPT_OUT_CHECK_FAILED", "Failed"); }
    if (optedOut !== false) throw new SmsFailure(optedOut ? "PROVIDER_OPT_OUT" : "SMS_OPT_OUT_CHECK_FAILED", optedOut ? "Skipped" : "Failed");
    try {
      const result = await this.client.send(new PublishCommand({ PhoneNumber: phone, Message: message, MessageAttributes: {
        "AWS.SNS.SMS.SMSType": { DataType: "String", StringValue: "Transactional" },
        "AWS.MM.SMS.OriginationNumber": { DataType: "String", StringValue: this.config.originationNumber },
        "AWS.SNS.SMS.MaxPrice": { DataType: "Number", StringValue: this.env.TOOLTAG_SMS_MAX_PRICE_USD || "0.50" },
      } }), { abortSignal: AbortSignal.timeout(15000) });
      if (!result.MessageId) throw new SmsFailure("SNS_DELIVERY_UNKNOWN", "Unknown");
      return result.MessageId;
    } catch (error) {
      if (error instanceof SmsFailure) throw error;
      const status = (error as { $metadata?: { httpStatusCode?: number } })?.$metadata?.httpStatusCode;
      throw new SmsFailure(status && status < 500 ? "SNS_REJECTED" : "SNS_DELIVERY_UNKNOWN", status && status < 500 ? "Failed" : "Unknown");
    }
  }
}
export function renderSms(event: string, payload: Record<string, unknown>, origin: string) {
  const site = new URL(origin); if (site.protocol !== "https:") throw new Error("SMS_PUBLIC_URL_REQUIRED");
  const normalized = event.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
  const defaults: Record<string, string> = { AGREEMENT_ACCEPTED_COPY: "Your quote and Agreement were accepted. Thank you for choosing ToolTag!", JOB_CONFIRMED: "Your ToolTag job is confirmed.", QUOTE_SENT: "Your ToolTag quote is ready to review.", COMPLETION_ACKNOWLEDGMENT: "Your items were delivered. Please confirm receipt in tracking.", COMPLETION_REMINDER: "Please review your ToolTag delivery confirmation.", PAYMENT_RECEIPT: "Your ToolTag payment was recorded.", FINAL_PAID_RECEIPT: "Your ToolTag final payment was recorded." };
  const text = typeof payload.text === "string" && payload.text.trim() ? payload.text : defaults[normalized];
  if (!text) throw new Error("SMS_TEMPLATE_UNAVAILABLE");
  let link = "";
  if (typeof payload.action_path === "string" && /^\/(status|review|pickup|payment|work|completion|extension)\//.test(payload.action_path)) {
    const url = new URL(payload.action_path, site);
    if (url.origin === site.origin) link = ` ${url.href}`;
  }
  const clean = text.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
  return `ToolTag: ${clean.slice(0, 420)}${clean.length > 420 ? "…" : ""}${link} Reply STOP to opt out. Help: ${new URL("/help", site).href}`;
}
