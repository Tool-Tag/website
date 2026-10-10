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

export function PickupFeeForm({
  token,
  amount,
  zelleEmail,
  venmoHandle,
  termsVersion,
}: {
  token: string;
  amount: number | string;
  zelleEmail?: string | null;
  venmoHandle?: string | null;
  termsVersion?: string | null;
}) {
  const [method, setMethod] = useState("Zelle");
  const [state, action, pending] = useActionState(
    customerAction.bind(null, "pickup-payment", token),
    {},
  );
  const venmoReady = Boolean(venmoHandle);

  return (
    <section className="panel">
      <h2>Pickup Service Fee</h2>
      <p>
        Amount due before Pickup scheduling: <strong>{money(amount)}</strong>
      </p>
      <p className="muted">
        This fee must be paid and confirmed by ToolTag before the Pickup & Return
        process can be scheduled or started.
      </p>

      <form action={action} className="stack">
        <input type="hidden" name="method" value={method} />

        <div>
          <span className="payment-method-label">Payment method</span>
          <div className="payment-method-tabs" role="tablist" aria-label="Payment method">
            <button
              type="button"
              role="tab"
              aria-selected={method === "Zelle"}
              className={method === "Zelle" ? "payment-method-tab active" : "payment-method-tab"}
              onClick={() => setMethod("Zelle")}
              disabled={!zelleEmail}
            >
              Zelle
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={method === "Venmo"}
              className={method === "Venmo" ? "payment-method-tab active" : "payment-method-tab"}
              onClick={() => setMethod("Venmo")}
            >
              Venmo
            </button>
          </div>
        </div>

        <div className="payment-method-panel">
          {method === "Zelle" && zelleEmail && (
            <>
              <CopyValue value={zelleEmail} label="Zelle email" />
              <label>
                Recommend Upload Proof · Payment screenshot (optional)
                <input
                  type="file"
                  name="proof"
                  accept="image/png,image/jpeg,image/webp"
                />
              </label>
            </>
          )}

          {method === "Venmo" && venmoHandle && (
            <>
              <CopyValue value={venmoHandle} label="Venmo" />
              <label>
                Recommend Upload Proof · Payment screenshot (optional)
                <input
                  type="file"
                  name="proof"
                  accept="image/png,image/jpeg,image/webp"
                />
              </label>
            </>
          )}

          {method === "Venmo" && !venmoHandle && (
            <div className="payment-coming-soon">Coming soon</div>
          )}
        </div>

        <div className="notice">
          <strong>Pickup & Return Terms v{termsVersion ?? "2.0"}</strong>
          <p>
            The Pickup Service Fee is subject to the Pickup cancellation terms you
            accepted with your ToolTag Agreement, including the applicable Friday
            6:00 PM cancellation deadline and missed-Pickup provisions.
          </p>
        </div>

        {state.error && <p className="notice error">{state.error}</p>}
        {state.ok && (
          <p className="notice success">
            Pickup fee payment submitted. ToolTag will verify the payment before
            Pickup scheduling is enabled.
          </p>
        )}

        <button
          disabled={
            pending ||
            state.ok ||
            (method === "Zelle" && !zelleEmail) ||
            (method === "Venmo" && !venmoReady)
          }
        >
          {pending ? "Submitting…" : "Submit Pickup Fee for Verification"}
        </button>
      </form>
    </section>
  );
}
