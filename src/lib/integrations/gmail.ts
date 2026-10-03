import { createHash, randomUUID } from "node:crypto";
import type { MailMessage, QuoteMailTransport } from "./quote-mail";
type Env = Record<string, string | undefined>;
export class MailFailure extends Error {
  constructor(public code: string) { super(code); }
}
export function mailEnabled(env: Env = process.env) {
  if (!["live", "test-delivery"].includes(env.TOOLTAG_MAIL_MODE || "")) return false;
  if (env.NODE_ENV !== "production" && env.TOOLTAG_MAIL_ALLOW_LOCAL_SEND !== "true") return false;
  if (env.VERCEL_ENV && env.VERCEL_ENV !== "production" && env.TOOLTAG_MAIL_MODE === "live") return false;
  return !!(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET && env.GOOGLE_REFRESH_TOKEN);
}
const safe = (value: string) => {
  if (!value || /[\r\n\0]/.test(value)) throw new MailFailure("MAIL_HEADER_INVALID");
  return value;
};
const mailbox = (value: string) => {
  safe(value);
  if (!/^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/.test(value)) throw new MailFailure("MAIL_ADDRESS_INVALID");
  return value;
};
const encoded = (value: string) => `=?UTF-8?B?${Buffer.from(safe(value)).toString("base64")}?=`;
const body = (value: string) => Buffer.from(value).toString("base64").match(/.{1,76}/g)?.join("\r\n") || "";
export function gmailMime(message: MailMessage, key: string) {
  const match = safe(message.from).match(/^(.+) <([^<>]+)>$/);
  if (!match) throw new MailFailure("MAIL_SENDER_INVALID");
  const boundary = `tooltag-${randomUUID()}`;
  return [`From: ${encoded(match[1])} <${mailbox(match[2])}>`, `To: ${mailbox(message.to)}`, `Reply-To: ${mailbox(message.replyTo || match[2])}`, `Subject: ${encoded(message.subject)}`, `Date: ${new Date().toUTCString()}`, `Message-ID: <${createHash("sha256").update(key).digest("hex")}@tooltag.martinlab.studio>`, "MIME-Version: 1.0", `Content-Type: multipart/alternative; boundary="${boundary}"`, "", `--${boundary}`, 'Content-Type: text/plain; charset="UTF-8"', "Content-Transfer-Encoding: base64", "", body(message.text), `--${boundary}`, 'Content-Type: text/html; charset="UTF-8"', "Content-Transfer-Encoding: base64", "", body(message.html), `--${boundary}--`, ""].join("\r\n");
}
export class GmailTransport implements QuoteMailTransport {
  constructor(private env: Env = process.env, private request: typeof fetch = fetch) {}
  async deliver(message: MailMessage, key: string) {
    if (!mailEnabled(this.env)) throw new MailFailure("MAIL_DISABLED");
    // Test delivery accepts only fixture messages already addressed to the test recipient.
    // Never redirect a real customer's private review link to a testing mailbox.
    if (this.env.TOOLTAG_MAIL_MODE === "test-delivery" && (!this.env.TOOLTAG_MAIL_TEST_RECIPIENT || message.to.toLowerCase() !== this.env.TOOLTAG_MAIL_TEST_RECIPIENT.toLowerCase())) throw new MailFailure("MAIL_TEST_RECIPIENT_REQUIRED");
    const raw = Buffer.from(gmailMime(message, key)).toString("base64url");
    let token: string;
    try {
      const res = await this.request("https://oauth2.googleapis.com/token", {method: "POST", cache: "no-store", signal: AbortSignal.timeout(10000), body: new URLSearchParams({client_id: this.env.GOOGLE_CLIENT_ID!, client_secret: this.env.GOOGLE_CLIENT_SECRET!, refresh_token: this.env.GOOGLE_REFRESH_TOKEN!, grant_type: "refresh_token"})});
      const data = await res.json();
      if (!res.ok || !data.access_token) throw new Error();
      token = data.access_token;
    } catch { throw new MailFailure("GMAIL_OAUTH_FAILED"); }
    let response: Response;
    try {
      response = await this.request("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {method: "POST", cache: "no-store", signal: AbortSignal.timeout(15000), headers: {Authorization: `Bearer ${token}`, "Content-Type": "application/json"}, body: JSON.stringify({raw})});
    } catch { throw new MailFailure("GMAIL_DELIVERY_UNKNOWN"); }
    if (!response.ok) throw new MailFailure(response.status >= 500 ? "GMAIL_DELIVERY_UNKNOWN" : `GMAIL_REJECTED_${response.status}`);
    try {
      const result = await response.json();
      if (typeof result.id !== "string" || !result.id) throw new Error();
      return {providerId: result.id};
    } catch { throw new MailFailure("GMAIL_DELIVERY_UNKNOWN"); }
  }
}
