import { mailSender } from "./mail-routing";
import { itemDetails, itemSubtotal } from "@/lib/domain/quote-summary";
import type { QuoteItem } from "@/lib/domain/quote-items";
import { money } from "@/lib/domain/money";
export type CommercialSnapshot = {
  code: string;
  revision: number;
  customer_name: string;
  customer_email: string;
  customer_phone: string;
  total: string;
  expires_at: string;
  items: QuoteItem[];
  policy: { title: string; version: number; content: string };
  notes?: string;
};
export type MailMessage = {
  from: string;
  replyTo?: string;
  to: string;
  subject: string;
  html: string;
  text: string;
  attachments?: { filename: string; content: Uint8Array }[];
};
export interface QuoteMailTransport {
  deliver(
    message: MailMessage,
    idempotencyKey: string,
  ): Promise<{ providerId: string }>;
}
const escape = (v: unknown) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
export function renderQuoteMail(
  snapshot: CommercialSnapshot,
  url: string,
  kind: "quote" | "confirmation",
  jobCode?: string,
): MailMessage {
  const parsed = new URL(url);
  if (!["http:", "https:"].includes(parsed.protocol))
    throw Error("Invalid review URL");
  const confirmation = kind === "confirmation";
  const subject = confirmation
    ? `ToolTag Order Confirmed — ${jobCode}`
    : `Your ToolTag Quote — ${snapshot.code}`;
  const summary = snapshot.items
    .map(
      (i) =>
        `${i.article} · Qty ${i.quantity} · ${itemSubtotal(i)}\n${itemDetails(i).join("\n")}`,
    )
    .join("\n\n");
  const intro = confirmation
    ? `Your ToolTag quote and Customer Agreement have been accepted.\nJob Number: ${jobCode}\nAgreed Total: ${money(snapshot.total)}`
    : "Thank you for choosing ToolTag. Your quote is ready for review.";
  const expiry = `${new Date(snapshot.expires_at).toISOString().replace("T", " ").slice(0, 16)} UTC`;
  const guidance = confirmation
    ? "Your approved work details and Agreement are available through the secure record below. We’ll use this Job Number for communication related to this work."
    : "Please review the complete quote, work details and ToolTag Customer Agreement using the secure link below. Please review spelling, design details, engraving locations, quantities, colors and other information carefully before accepting. If anything needs to be changed, contact ToolTag before accepting the quote.";
  const text = `Hi ${snapshot.customer_name.split(" ")[0]},\n\n${intro}\n\nQUOTE SUMMARY\n${summary}\n\nQuote Total: ${money(snapshot.total)}\n${confirmation ? "" : `Valid Until: ${expiry}\n`}\n${guidance}\n\n${confirmation ? "View accepted record" : "Review & Accept Quote"}: ${url}\n\nToolTag\nQuote: ${snapshot.code} · Version ${snapshot.revision}`;
  const html = `<!doctype html><html lang="en"><body style="font-family:Arial,sans-serif;background:#080b10;color:#f5f6fa;padding:24px"><main style="max-width:640px;margin:auto"><h1 style="color:#e7b84b">ToolTag</h1><p>Hi ${escape(snapshot.customer_name.split(" ")[0])},</p><p style="white-space:pre-line">${escape(intro)}</p><h2>Quote summary</h2><div style="white-space:pre-line">${escape(summary)}</div><p><strong>Quote Total: ${escape(money(snapshot.total))}</strong></p>${confirmation ? "" : `<p>Valid Until: ${escape(expiry)}</p>`}<p>${escape(guidance)}</p><p><a style="display:inline-block;background:#3975ff;color:white;padding:14px 20px;border-radius:8px" href="${escape(url)}">${confirmation ? "View accepted record" : "Review &amp; Accept Quote"}</a></p><footer>ToolTag · ${escape(snapshot.code)} · Version ${snapshot.revision}</footer></main></body></html>`;
  return {
    ...mailSender(confirmation ? "AGREEMENT_ACCEPTED" : "QUOTE_SENT"),
    to: snapshot.customer_email,
    subject,
    html,
    text,
  };
}
export async function prepareQuoteMail(
  message: MailMessage,
  options: {
    mode?: string;
    transport?: QuoteMailTransport;
    idempotencyKey: string;
  },
) {
  if (
    options.mode !== "live" ||
    !options.transport ||
    message.from === "Not configured"
  )
    return {
      status: "Pending Integration" as const,
      message,
      delivered: false,
    };
  const receipt = await options.transport.deliver(
    message,
    options.idempotencyKey,
  );
  return {
    status: "Sent" as const,
    message,
    delivered: true,
    providerId: receipt.providerId,
  };
}
