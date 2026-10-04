"use client";

import { useActionState, useState } from "react";
import { customerAction } from "@/app/actions";
import { money } from "@/lib/domain/money";

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
            <p>
              Send Zelle to <strong>{zelleEmail}</strong>.
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
            <p>
              Send Venmo to <strong>{venmoHandle}</strong>.
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
