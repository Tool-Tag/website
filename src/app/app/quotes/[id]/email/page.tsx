import { context } from "@/lib/domain/context";
import {
  renderQuoteMail,
} from "@/lib/integrations/quote-mail";
import { headers } from "next/headers";
export default async function EmailPreview({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const { db } = await context();
  const { data, error } = await db.rpc("quote_delivery", { p_id: id });
  if (error || !data?.token)
    return (
      <p>
        Send the Quote first to prepare the customer link and email preview.
      </p>
    );
  const h = await headers();
  const origin =
    process.env.TOOLTAG_PUBLIC_URL ||
    `${h.get("x-forwarded-proto") || "http"}://${h.get("host")}`;
  const url = new URL(`/review/${data.token}`, origin).toString();
  const mail = renderQuoteMail(
    data.snapshot,
    url,
    data.accepted ? "confirmation" : "quote",
    data.job_code,
  );
  if (!data.accepted && data.recipient) mail.to = data.recipient;
  return (
    <>
      <h1>Email Preview</h1>
      <p>This preview does not send email. Check delivery status in Settings.</p>
      <p>
        From: {mail.from} · To: {mail.to} · Reply to: {mail.replyTo}
      </p>
      <h2>{mail.subject}</h2>
      <iframe
        title="HTML Email"
        sandbox=""
        srcDoc={mail.html}
        style={{ width: "100%", height: 650, border: 0 }}
      />
      <details>
        <summary>Text Version</summary>
        <pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>
          {mail.text}
        </pre>
      </details>
    </>
  );
}
