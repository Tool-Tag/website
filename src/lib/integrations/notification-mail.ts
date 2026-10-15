import { mailSender } from "./mail-routing";
import type { MailMessage } from "./quote-mail";

const escape = (value: string) =>
  value.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!,
  );

export function renderNotification(
  subject: string,
  text: string,
  to: string,
  event: string,
  link?: string,
  actionLabel = "Review details",
  proofLink?: string,
): MailMessage {
  if (link && new URL(link).protocol !== "https:")
    throw new Error("Secure link required");

  if (proofLink && new URL(proofLink).protocol !== "https:") throw new Error("Secure proof link required");

  return {
    ...mailSender(event),
    to,
    subject,
    text: `${text}${link ? `\n\n${actionLabel}: ${link}` : ""}${proofLink ? `\n\nView refund screenshot: ${proofLink}` : ""}\n\nToolTag`,
    html: `<!doctype html><html lang="en"><body style="font-family:Arial,sans-serif;background:#080b10;color:#f5f6fa;padding:24px"><main style="max-width:640px;margin:auto"><h1 style="color:#e7b84b">ToolTag</h1><h2>${escape(subject)}</h2><p style="white-space:pre-line">${escape(text)}</p>${
      link
        ? `<p><a style="background:#3975ff;color:white;padding:14px 20px;display:inline-block;text-decoration:none;border-radius:8px" href="${escape(link)}">${escape(actionLabel)}</a></p>`
        : ""
    }${proofLink ? `<p><a href="${escape(proofLink)}">View refund screenshot</a></p>` : ""}<footer>ToolTag</footer></main></body></html>`,
  };
}
