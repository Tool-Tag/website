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
      window.setTimeout(() => setCopied(false), 1500);
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
      <button type="button" className="copy-button" onClick={copy}>
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

export function CancellationBalanceForm({
  token,
  amount,
  zelleEmail,
  venmoHandle,
}: {
  token: string;
  amount: number | string;
  zelleEmail?: string | null;
  venmoHandle?: string | null;
}) {
  const [method, setMethod] = useState("Cash");
  const [state, action, pending] = useActionState(
    customerAction.bind(null, "cancellation-payment", token),
    {},
  );

  return (
    <section className="panel">
      <p className="status-kicker">Cancellation balance</p>
      <h2>{money(amount)} due</h2>
      <p className="muted">
        This is the remaining amount due under the cancellation terms you accepted.
        If ToolTag already has your items, Return remains on hold until this payment
        is confirmed.
      </p>

      <form action={action} className="stack">
        <input type="hidden" name="method" value={method} />

        <div>
          <span className="payment-method-label">Payment method</span>
          <div
            className="payment-method-tabs"
            role="tablist"
            aria-label="Payment method"
          >
            <button
              type="button"
              role="tab"
              aria-selected={method === "Cash"}
              className={
                method === "Cash"
                  ? "payment-method-tab active"
                  : "payment-method-tab"
              }
              onClick={() => setMethod("Cash")}
            >
              Cash
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={method === "Zelle"}
              className={
                method === "Zelle"
                  ? "payment-method-tab active"
                  : "payment-method-tab"
              }
              disabled={!zelleEmail}
              onClick={() => setMethod("Zelle")}
            >
              Zelle
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={method === "Venmo"}
              className={
                method === "Venmo"
                  ? "payment-method-tab active"
                  : "payment-method-tab"
              }
              onClick={() => setMethod("Venmo")}
            >
              Venmo
            </button>
          </div>
        </div>

        <div className="payment-method-panel">
          {method === "Cash" && (
            <p className="muted">
              Pay cash directly to ToolTag. Return remains on hold until ToolTag
              confirms the cash was received.
            </p>
          )}

          {method === "Zelle" && zelleEmail && (
            <>
              <CopyValue value={zelleEmail} label="Zelle email" />
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

          {method === "Venmo" && !venmoHandle && (
            <div className="payment-coming-soon">Coming soon</div>
          )}
        </div>

        {state.error && <p className="notice error">{state.error}</p>}
        {state.ok && (
          <p className="notice success">
            Payment submitted. ToolTag will verify it before the cancellation
            balance is marked paid.
          </p>
        )}

        <button
          disabled={
            pending ||
            state.ok ||
            (method === "Zelle" && !zelleEmail) ||
            (method === "Venmo" && !venmoHandle)
          }
        >
          {pending ? "Submitting…" : "Submit Cancellation Payment"}
        </button>
      </form>
    </section>
  );
}
