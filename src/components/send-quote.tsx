"use client";
import { useActionState, useEffect, useState } from "react";
import { mutate } from "@/app/actions";
export function SendQuote({ id, email, companyEmail, sent = false, lastRequestedAt }: { id: string; email?: string; companyEmail?: string; sent?: boolean; lastRequestedAt?: string }) {
  const recipients = [
    { label: "Personal Email", email: email?.trim() || "" },
    { label: "Company Email", email: companyEmail?.trim() || "" },
  ].filter((entry, index, all) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(entry.email) && all.findIndex((other) => other.email.toLowerCase() === entry.email.toLowerCase()) === index);
  const [state, action, pending] = useActionState(
    mutate.bind(null, sent ? "resend-quote" : "send-quote", `/app/quotes/${id}`),
    {},
  );
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(0);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, []);
  const requestedAt = state.mailRequestedAt || lastRequestedAt;
  const isResend = sent || Boolean(state.mailRequestedAt);
  const seconds = isResend && requestedAt ? Math.max(0, Math.ceil((Date.parse(requestedAt) + 90000 - (now || Date.parse(requestedAt))) / 1000)) : 0;
  return (
    <>
      <form action={action}>
        <input type="hidden" name="id" value={id} />
        <input type="hidden" name="resend" value={isResend ? "true" : "false"} />
        {recipients.length > 1 ? (
          <label>
            Which email do you want to send the Quote to?
            <select name="recipient" required defaultValue="" disabled={pending}>
              <option value="" disabled>Select an Email…</option>
              {recipients.map((entry) => <option key={entry.email} value={entry.email}>{entry.label}: {entry.email}</option>)}
            </select>
          </label>
        ) : (
          <>
            <input type="hidden" name="recipient" value={recipients[0]?.email || ""} />
            <p>{recipients.length ? `Send to: ${recipients[0].email}` : "Add a customer email before sending."}</p>
          </>
        )}
        <button disabled={pending || !recipients.length || seconds > 0}>
          {pending ? "Preparing…" : seconds > 0 ? `Resend in ${seconds}s` : isResend ? "Resend Quote" : "Send Quote"}
        </button>
        {!isResend && <label className="checkbox">
          <input type="checkbox" name="regenerate" />
          Regenerate link and invalidate the previous one
        </label>}
        {isResend && <p className="muted">Resending keeps the recipient, secure link, and expiration date.</p>}
        {state.error && (
          <p role="alert" className="notice error">
            {state.error}
          </p>
        )}
        {state.link && (
          <div className="notice">
            <p>
              {state.mailStatus || "Quote ready. You can copy the link to share it."}
            </p>
            <input
              aria-label="Enlace privado"
              readOnly
              value={window.location.origin + state.link}
            />
            <div className="actions">
              <button
                type="button"
                className="secondary"
                onClick={async () => {
                  setCopied(false);
                  try {
                    await navigator.clipboard.writeText(
                      window.location.origin + state.link!,
                    );
                    setCopied(true);
                  } catch {
                    /* The selectable field remains available. */
                  }
                }}
              >
                {copied ? "Copiado" : "Copiar enlace"}
              </button>
              <a href={state.link} target="_blank" rel="noreferrer">
                View Customer Page
              </a>
            </div>
          </div>
        )}
      </form>
      <p>
        <a href={`/app/quotes/${id}/email`}>Email Preview</a>
      </p>
    </>
  );
}
