"use client";

import { useActionState, useState } from "react";
import { customerAction, type ActionState } from "@/app/actions";

type Assessment = {
  allowed?: boolean;
  rule?: string;
  items_total?: number;
  items_started?: number;
  items_finished?: number;
  service_amount?: number;
  service_charge_percent?: number;
  service_charge_amount?: number;
  pickup_fee_amount?: number;
  pickup_fee_refundable?: boolean;
  pickup_fee_refund_amount?: number;
  refund_eligible_amount?: number;
  amount_due?: number;
};

export function CancellationAction({
  token,
  kind,
  id,
  code,
  assessment,
}: {
  token: string;
  kind: "cancel-job" | "cancel-quote" | "status-cancel";
  id?: string;
  code: string;
  assessment?: Assessment | null;
}) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState<ActionState, FormData>(
    customerAction.bind(null, kind, token),
    {},
  );

  if (state.ok) {
    return (
      <div className="notice success">
        Cancellation confirmed. Check your email for the cancellation details and any applicable refund information.
      </div>
    );
  }

  const allowed = assessment?.allowed !== false;
  const total = Number(assessment?.items_total ?? 0);
  const started = Number(assessment?.items_started ?? 0);
  const finished = Number(assessment?.items_finished ?? 0);
  const pickupFee = Number(assessment?.pickup_fee_amount ?? 0);
  const refund = Number(assessment?.refund_eligible_amount ?? 0);
  const amountDue = Number(assessment?.amount_due ?? 0);
  const chargePercent = Number(assessment?.service_charge_percent ?? 0);
  const chargeAmount = Number(assessment?.service_charge_amount ?? 0);
  const pickupRefund = Number(assessment?.pickup_fee_refund_amount ?? 0);

  return (
    <>
      <button
        className="secondary"
        type="button"
        disabled={!allowed}
        onClick={() => setOpen(true)}
      >
        {allowed ? "Cancel Service" : "Cancellation unavailable"}
      </button>

      {!allowed && assessment && (
        <div className="notice error">
          <strong>THIS JOB CAN NO LONGER BE CANCELLED</strong>
          <br />
          The approved engraving work has been completed. The full accepted amount remains due under the accepted Agreement.
        </div>
      )}

      {open && (
        <dialog open>
          <form action={action}>
            {id && <input type="hidden" name="id" value={id} />}
            <h2>Cancel {code}?</h2>

            {assessment ? (
              <>
                {total > 0 && (
                  <p>
                    Engraving progress: <strong>{started}/{total}</strong> items started ·{" "}
                    <strong>{finished}/{total}</strong> items Finished
                  </p>
                )}

                <p>
                  Cancellation rule: <strong>{assessment.rule ?? "Current Agreement terms"}</strong>
                </p>

                {chargePercent > 0 && (
                  <p>
                    Service amount due under the cancellation policy:{" "}
                    <strong>{chargePercent}%</strong> (${chargeAmount.toFixed(2)})
                  </p>
                )}

                {pickupFee > 0 && !assessment.pickup_fee_refundable && (
                  <div className="notice error">
                    <strong>PICKUP FEE: NON-REFUNDABLE</strong>
                    <br />
                    Under the Pickup Service Terms you accepted, the applicable Pickup fee is non-refundable at the current stage or after the applicable cancellation deadline.
                  </div>
                )}

                {pickupFee > 0 && assessment.pickup_fee_refundable && (
                  <p className="notice success">
                    Pickup fee eligible for refund: ${pickupRefund.toFixed(2)}
                  </p>
                )}

                {refund <= 0 && (
                  <div className="notice error">
                    <strong>NOT ELIGIBLE FOR A REFUND</strong>
                  </div>
                )}

                {refund > 0 && (
                  <p>
                    Eligible refund: <strong>${refund.toFixed(2)}</strong>. Approved refunds are generally processed within 5–7 business days after ToolTag confirms the refund.
                  </p>
                )}

                {amountDue > 0 && (
                  <p className="notice error">
                    Outstanding amount due after cancellation: <strong>${amountDue.toFixed(2)}</strong>.
                    Customer-owned items will not be released while an applicable Job balance remains unpaid, except where applicable law requires otherwise.
                  </p>
                )}
              </>
            ) : (
              <p>
                Are you sure you want to cancel this active Quote? This will stop the Quote from continuing through the normal approval flow.
              </p>
            )}

            {state.error && <div className="notice error">{state.error}</div>}

            <div className="actions">
              <button type="submit" disabled={pending}>
                {pending ? "Cancelling…" : "Yes, cancel"}
              </button>
              <button
                className="secondary"
                type="button"
                disabled={pending}
                onClick={() => setOpen(false)}
              >
                Keep service
              </button>
            </div>
          </form>
        </dialog>
      )}
    </>
  );
}
