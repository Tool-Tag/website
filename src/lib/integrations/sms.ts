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
const SMS_EVENT_STAGE: Record<string, string> = {
 PICKUP_ROUTE_DEPARTED: "Driver En Route", RETURN_ROUTE_DEPARTED: "Driver En Route",
 PICKUP_EN_ROUTE: "Driver En Route", RETURN_EN_ROUTE: "Driver En Route",
 PICKUP_DRIVER_NEARBY: "3 Stops Away", RETURN_DRIVER_NEARBY: "3 Stops Away",
 PICKUP_ARRIVED: "Driver Arrived", RETURN_ARRIVED: "Driver Arrived",
 PICKUP_SCHEDULED: "Pickup Scheduled", RETURN_SCHEDULED: "Return Scheduled",
 PICKUP_RESCHEDULED: "Pickup Rescheduled", RETURN_RESCHEDULED: "Return Rescheduled",
 PICKUP_MISSED: "Pickup Missed", RETURN_MISSED: "Delivery Pending",
 PAYMENT_DUE: "Payment Due", PAYMENT_CUTOFF_REMINDER: "Payment Reminder",
 PICKUP_FEE_REQUIRED: "Pickup Fee Due", AGREEMENT_ACCEPTED_COPY: "Agreement Accepted",
 JOB_CONFIRMED: "Confirmed", JOB_READY: "Ready", COMPLETION_ACKNOWLEDGMENT: "Delivered",
 COMPLETION_REMINDER: "Delivery Confirmation", PAYMENT_RECEIPT: "Payment Received",
 FINAL_PAID_RECEIPT: "Paid", QUOTE_SENT: "Quote Ready", QUOTE_EXPIRATION_REMINDER: "Quote Reminder",
 DRIVER_UNAVAILABLE: "Route Delayed", ROUTE_INTERRUPTED: "Route Delayed",
 JOB_STATUS_LINK: "Confirmed", DELIVERY_IN_PROGRESS: "Delivery In Progress", SHOP_PICKUP: "Shop Pickup",
};
const SMS_WORK_STAGE: Record<string,string> = {
 "Authorized":"Confirmed","Scheduled":"Scheduled","Receiving":"Receiving","In Process":"In Process",
 "Pickup Scheduled":"Pickup Scheduled","Pickup In Progress":"Pickup In Progress","Picked Up":"Picked Up",
 "Return Scheduled":"Return Scheduled","Out for Delivery":"Out for Delivery","Delivered":"Delivered",
 "Pending Agreement":"Agreement Pending","Issue / Review":"Review","Ready":"Ready",
 "Not Started":"Scheduled","Receiving Evidence":"Receiving","Receiving Documentation":"Receiving",
 "Received at Shop":"Received at Shop","Preparing":"Preparation","Engraving":"Engraving",
 "Final Evidence":"Engraving","Final Details":"Final Details","Delivery In Progress":"Delivery In Progress",
 "Awaiting Delivery Acceptance":"Delivery Confirmation","Payment":"Payment Pending",
 "Payment Verification":"Payment Verification","Closed":"Completed","Completed":"Completed",
 "Ready for Delivery":"Ready for Delivery","Pending Delivery":"Delivery Pending",
 "Cancellation Requested / Production Hold":"On Hold","Issue Review":"Review","Cancelled":"Cancelled",
};
export function renderSms(event: string, payload: Record<string, unknown>, origin: string) {
 const site=new URL(origin);if(site.protocol!=="https:" || site.username || site.password)throw new Error("SMS_PUBLIC_URL_REQUIRED");
 const normalized=event.toUpperCase().replace(/[^A-Z0-9]+/g,"_");
 const stage=normalized==="JOB_STATUS_UPDATE" ? SMS_WORK_STAGE[String(payload.stage)]??"Status Updated" : SMS_EVENT_STAGE[normalized];
 if(!stage)throw new Error("SMS_TEMPLATE_UNAVAILABLE");
 const code=String(payload.job_code??""),path=String(payload.action_path??"");
 if(!/^[A-Z0-9][A-Z0-9/-]{0,63}$/.test(code)||!/^\/(status|review)\/[A-Za-z0-9-]{8,200}$/.test(path))throw new Error("SMS_CONTEXT_UNAVAILABLE");
 const url=new URL(path,site);if(url.origin!==site.origin)throw new Error("SMS_CONTEXT_UNAVAILABLE");
 // Keep capability links intact; plain English/ASCII avoids UCS-2 segmentation.
 return "Your order "+code+" moved to "+stage+". Details: "+url.href;
}
