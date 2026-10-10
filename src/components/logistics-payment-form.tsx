"use client";

import { useActionState, useEffect, useMemo, useState } from "react";
import { customerAction, type ActionState } from "@/app/actions";
import { PaymentProofInput } from "@/components/payment-proof-input";
import { money } from "@/lib/domain/money";

type LogisticsPayment = {
  job_code: string;
  customer_name: string;
  fee_amount: number | string;
  balance_due: number | string;
  payment_status: string;
  payment_scope?: "full" | "fee_only" | null;
  payment_method?: string | null;
  memo: string;
  methods?: {
    zelle?: string | null;
    venmo?: string | null;
  };
};

function CopyValue({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="payment-copy-row">
      <div>
        <small>{label}</small>
        <strong>{value}</strong>
      </div>
      <button
        type="button"
        className="copy-button"
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(value);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
          } catch {
            setCopied(false);
          }
        }}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

export function LogisticsPaymentForm({
  token,
  payment,
  cardConfigured,
}: {
  token: string;
  payment: LogisticsPayment;
  cardConfigured: boolean;
}) {
  const zelle = payment.methods?.zelle?.trim() || "";
  const venmo = payment.methods?.venmo?.trim() || "";
  const initialMethod = cardConfigured ? "Card" : zelle ? "Zelle" : "Venmo";
  const [scope, setScope] = useState<"full" | "fee_only">(
    payment.payment_scope ?? "fee_only",
  );
  const [method, setMethod] = useState(initialMethod);
  const [state, action, pending] = useActionState<ActionState, FormData>(
    async (previous, form) => {
      try { return await customerAction("logistics-payment", token, previous, form); }
      catch { return {error: "Payment submission failed. Please try again with a smaller screenshot."}; }
    },
    {},
  );

  useEffect(() => {
    if (!state.link) return;
    if (/^https?:\/\//.test(state.link)) window.location.assign(state.link);
  }, [state.link]);

  const amount = useMemo(
    () =>
      scope === "full"
        ? Number(payment.balance_due || 0)
        : Number(payment.fee_amount || 0),
    [scope, payment.balance_due, payment.fee_amount],
  );

  if (payment.payment_status === "paid_confirmed") {
    return (
      <section className="panel">
        <h2>Payment confirmed</h2>
        <p className="notice success">
          Your logistics payment is confirmed. ToolTag can continue with the
          applicable scheduling/work stage.
        </p>
      </section>
    );
  }

  if (payment.payment_status === "pending_verification") {
    return (
      <section className="panel">
        <h2>Payment pending verification</h2>
        <p>
          <strong>Memo:</strong> {payment.memo}
        </p>
        <p className="notice">
          We&apos;ll verify your payment within 24 hours and notify you by email.
        </p>
      </section>
    );
  }

  return (
    <section className="panel">
      <h2>Pay logistics fee</h2>
      <p>
        Logistics fee: {money(payment.fee_amount)}. Card, Zelle, or Venmo. This
        fee must be paid before we can schedule your pickup. Cash is not accepted
        for this fee.
      </p>

      <form action={action} className="stack">
        <input type="hidden" name="scope" value={scope} />
        <input type="hidden" name="method" value={method} />

        <fieldset className="payment-choice">
          <legend>How much would you like to pay now?</legend>
          <label className="logistics-option">
            <input
              type="radio"
              checked={scope === "full"}
              onChange={() => setScope("full")}
            />
            <span>
              <strong>Pay everything now</strong>
              <small>{money(payment.balance_due)}</small>
              <p>Pay the engraving work and logistics fee now.</p>
            </span>
          </label>
          <label className="logistics-option">
            <input
              type="radio"
              checked={scope === "fee_only"}
              onChange={() => setScope("fee_only")}
            />
            <span>
              <strong>Pay only the logistics fee now</strong>
              <small>{money(payment.fee_amount)}</small>
              <p>
                Pay the work balance when the finished items are delivered or
                picked up.
              </p>
            </span>
          </label>
        </fieldset>

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
              aria-selected={method === "Card"}
              className={
                method === "Card"
                  ? "payment-method-tab active"
                  : "payment-method-tab"
              }
              onClick={() => setMethod("Card")}
              disabled={!cardConfigured}
            >
              Card {!cardConfigured && <small>Not configured</small>}
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
              disabled={!zelle}
            >
              Zelle {!zelle && <small>Not configured</small>}
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
              disabled={!venmo}
            >
              Venmo {!venmo && <small>Not configured</small>}
            </button>
          </div>
        </div>

        {method === "Card" && cardConfigured && (
          <div className="payment-method-panel">
            <p>
              Amount to charge now: <strong>{money(amount.toFixed(2))}</strong>
            </p>
            <p className="muted">
              You will continue to Stripe&apos;s secure hosted checkout. ToolTag
              marks the payment confirmed only after Stripe confirms it.
            </p>
          </div>
        )}

        {method === "Zelle" && zelle && (
          <div className="payment-method-panel">
            <CopyValue label="ToolTag Zelle" value={zelle} />
            <CopyValue label="Memo" value={payment.memo} />
            <p>
              In the Zelle/Venmo description or memo, write:{" "}
              <strong>{payment.memo}</strong> so we can match your payment.
            </p>
          </div>
        )}

        {method === "Venmo" && venmo && (
          <div className="payment-method-panel">
            <CopyValue label="ToolTag Venmo" value={venmo} />
            <CopyValue label="Memo" value={payment.memo} />
            <p>
              In the Zelle/Venmo description or memo, write:{" "}
              <strong>{payment.memo}</strong> so we can match your payment.
            </p>
          </div>
        )}

        {["Zelle", "Venmo"].includes(method) && <label>Payment screenshot (optional)<PaymentProofInput /><small>Recommend Upload Proof</small></label>}
        {state.error && <p className="notice error">{state.error}</p>}
        {state.ok && !state.link && (
          <p className="notice">
            We&apos;ll verify your payment within 24 hours and notify you by email.
          </p>
        )}

        <button
          disabled={
            pending ||
            (method === "Card" && !cardConfigured) ||
            (method === "Zelle" && !zelle) ||
            (method === "Venmo" && !venmo)
          }
        >
          {pending
            ? "Submitting…"
            : method === "Card"
              ? `Pay ${money(amount.toFixed(2))} by card`
              : "I've sent the payment"}
        </button>
      </form>
    </section>
  );
}
