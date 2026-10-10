"use client";

import { useActionState, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { customerAction, type ActionState } from "@/app/actions";
import { PaymentProofInput } from "@/components/payment-proof-input";
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
  cardConfigured = false,
  routePayment = false,
}: {
  cardConfigured?: boolean;
  routePayment?: boolean;
  token: string;
  balanceDue: number | string;
  zelleEmail?: string | null;
  venmoHandle?: string | null;
}) {
  const router = useRouter();
  const [method, setMethod] = useState("Cash");
  const [state, action, pending] = useActionState<ActionState, FormData>(
    async (previous, form) => {
      try { return await customerAction(routePayment ? "route-payment" : "payment", token, previous, form); }
      catch { return {error: "Payment submission failed. Please try again with a smaller screenshot."}; }
    },
    {},
  );

  useEffect(() => {
    if (state.link) {if(state.link.startsWith("https://")) window.location.assign(state.link);else router.push(state.link);}
  }, [state.link, router]);

  const venmoReady = Boolean(venmoHandle);

  return (
    <section className="panel">
      <h2>Payment</h2>
      <p>
        Balance due: <strong>{money(balanceDue)}</strong>
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
            <button type="button" role="tab" aria-selected={method === "Card"} onClick={()=>setMethod("Card")} disabled={!cardConfigured}>Card {!cardConfigured && <small>Not configured</small>}</button>
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
              onClick={() => setMethod("Zelle")}
              disabled={!zelleEmail}
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
          {method === "Card" && <p>Continue to Stripe secure checkout. Payment is confirmed only after the provider confirms it.</p>}
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
                <PaymentProofInput required />
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
                <PaymentProofInput required />
              </label>
            </>
          )}

          {method === "Venmo" && !venmoHandle && (
            <div className="payment-coming-soon">Coming soon</div>
          )}
        </div>

        {state.error && (
          <p role="alert" className="notice error">
            {state.error}
          </p>
        )}

        {state.ok && (
          <p role="status" className="notice success">
            Payment choice submitted. ToolTag confirms electronic payments or collects cash at handover; selecting Cash does not mark the Job paid.
          </p>
        )}

        <button disabled={pending || state.ok || (method === "Card" && !cardConfigured) || (method === "Venmo" && !venmoReady)}>
          {pending ? "Submitting…" : "Submit payment for verification"}
        </button>
      </form>
    </section>
  );
}
