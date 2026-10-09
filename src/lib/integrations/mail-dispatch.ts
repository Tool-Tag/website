import type { SupabaseClient } from "@supabase/supabase-js";
import { createClient } from "@supabase/supabase-js";
import { GmailTransport, mailEnabled, MailFailure } from "./gmail";
import { renderNotification } from "./notification-mail";
import { renderQuoteMail } from "./quote-mail";
import { renderJobReceipt } from "./receipt-mail";
import { mailSender } from "./mail-routing";
export async function dispatchQuoteMail(db: SupabaseClient, quoteId?: string) {
  if (!mailEnabled()) return "Email pending: configure Google Workspace. You can copy the link.";
  const origin = process.env.TOOLTAG_PUBLIC_URL;
  if (!origin || !/^https:\/\//.test(origin)) return "Email pending: the secure public site URL is missing.";
  const testRecipient = process.env.TOOLTAG_MAIL_MODE === "test-delivery" ? process.env.TOOLTAG_MAIL_TEST_RECIPIENT : null;
  if (testRecipient === "" || testRecipient === undefined) return "Email pending: configure the test recipient.";
  let sent = 0;
  try {
    for (let i = 0; i < 5; i++) {
      const {data: event, error} = await db.rpc("claim_mail_for_mode", {p_quote: quoteId || null, p_test_recipient: testRecipient,p_mode:process.env.TOOLTAG_MAIL_MODE});
      if (error) return "Email pending: the mail queue could not be checked.";
      if (!event) break;
      let providerId: string | null = null, failure: string | null = null;
      try {
        const message = event.payload.template === "job_receipt"
          ? renderJobReceipt(event.payload.snapshot,event.recipient)
          : event.payload.template === "notification"
          ? renderNotification(
              event.payload.subject,
              event.payload.text,
              event.recipient,
              event.event,
              event.action_path
                ? new URL(event.action_path, origin).href
                : event.completion_token
                  ? new URL(`/completion/${event.completion_token}`, origin).href
                  : undefined,
              event.event === "Completion acknowledgment"
                ? "Accept Delivery"
                : ["JOB_STATUS_LINK", "JOB_STATUS_UPDATE"].includes(event.event)
                  ? "View Job Status"
                  : "Review details",
            )
          : renderQuoteMail(event.payload.snapshot, new URL(`/review/${event.token}`, origin).href, event.event === "Agreement accepted copy" ? "confirmation" : "quote", event.payload.job_code);
        Object.assign(message, mailSender(event.event), {to: event.recipient});
        if (event.event === "Quote expiration reminder") message.subject = `Your ToolTag Quote expires soon — ${event.payload.snapshot.code}`;
        providerId = (await new GmailTransport().deliver(message, event.dedupe_key)).providerId;
      } catch (error) { failure = error instanceof MailFailure ? error.code : "MAIL_RENDER_FAILED"; }
      const {data: recorded, error: recordError} = await db.rpc("finish_quote_mail", {p_id:event.id,p_claim:event.mail_claim,p_provider_id:providerId,p_error:failure});
      if (recordError || !recorded) return "Review the delivery log before retrying; the result is still awaiting confirmation.";
      if (failure) return `The email could not be confirmed (${failure}). You can copy the link.`;
      sent++;
    }
    return sent ? "Gmail accepted the email for delivery." : "No new emails are waiting to be sent. Review the notification log.";
  } catch { return "Email pending. You can copy the link."; }
}
export async function dispatchWorkerMail() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!key || !url || !mailEnabled()) return;
  await dispatchQuoteMail(createClient(url, key, {auth:{persistSession:false,autoRefreshToken:false}}));
}
