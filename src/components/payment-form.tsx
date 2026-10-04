"use client";

import { useActionState, useState } from "react";
import { customerAction } from "@/app/actions";
import { money } from "@/lib/domain/money";

function CopyValue({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div className="payment-copy-row">
      <div>
        <small>{label}</small>
        <strong>{value}</strong>
      </div>
      <button
        type="button"
        className="copy-button"
        onClick={copy}
        aria-label={`Copy ${label}`}
        title={`Copy ${label}`}
      >
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M8 7V5.5A2.5 2.5 0 0 1 10.5 3h7A2.5 2.5 0 0 1 20 5.5v7a2.5 2.5 0 0 1-2.5 2.5H16v1.5A2.5 2.5 0 0 1 13.5 19h-7A2.5 2.5 0 0 1 4 16.5v-7A2.5 2.5 0 0 1 6.5 7H8Zm2 0h3.5A2.5 2.5 0 0 1 16 9.5V13h1.5a.5.5 0 0 0 .5-.5v-7a.5.5 0 0 0-.5-.5h-7a.5.5 0 0 0-.5.5V7Zm-3.5 2a.5.5 0 0 0-.5.5v7a.5.5 0 0 0 .5.5h7a.5.5 0 0 0 .5-.5v-7a.5.5 0 0 0-.5-.5h-7Z" />
        </svg>
        <span>{copied ? "Copied" : "Copy"}</span>
      </button>
    </div>
  );
}

export function PaymentForm({
  token,
  balanceDue,
  zelleEmail,
  venmoHandle,
}: {
  token: string;
  balanceDue: number | string;
  zelleEmail?: string | null;
  venmoHandle?: string | null;
}) {
  const [method, setMethod] = useState("Cash");
  const [state, action, pending] = useActionState(
    customerAction.bind(null, "payment", token),
    {},
  );

  return (
    <section className="panel">
      <h2>Payment</h2>
      <p>
        Balance due: <strong>{money(balanceDue)}</strong>
      </p>

      <form action={action} className="stack">
        <label>
          Payment method
          <select
            name="method"
            value={method}
            onChange={(event) => setMethod(event.target.value)}
          >
            <option value="Cash">Cash</option>
            {zelleEmail && <option value="Zelle">Zelle</option>}
            {venmoHandle && <option value="Venmo">Venmo</option>}
          </select>
        </label>

        {method === "Cash" && (
          <p className="muted">
            Pay cash directly to ToolTag. Your payment will remain pending until
            ToolTag confirms the cash was received.
          </p>
        )}

        {method === "Zelle" && zelleEmail && (
          <>
            <CopyValue value={zelleEmail} label="Zelle email" />
            <p className="muted">
              Copy the address above before sending your payment to help avoid typing errors.
            </p>
            <label>
              Payment screenshot
              <input
                type="file"
                name="proof"
                accept="image/png,image/jpeg,image/webp"
                required
              />
            </label>
          </>
        )}

        {method === "Venmo" && venmoHandle && (
          <>
            <CopyValue value={venmoHandle} label="Venmo" />
            <p className="muted">
              Copy the Venmo account above before sending your payment.
            </p>
            <label>
              Payment screenshot
              <input
                type="file"
                name="proof"
                accept="image/png,image/jpeg,image/webp"
                required
              />
            </label>
          </>
        )}

        {state.error && (
          <p role="alert" className="notice error">
            {state.error}
          </p>
        )}

        {state.ok && (
          <p role="status" className="notice success">
            Payment submitted. ToolTag will verify it before marking the Job as paid.
          </p>
        )}

        <button disabled={pending || state.ok}>
          {pending ? "Submitting…" : "Submit payment for verification"}
        </button>
      </form>
    </section>
  );
}
