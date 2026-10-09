"use client";

import { useActionState, useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { statusCancellationAction } from "@/app/status-actions";
import type { CancellationAssessmentPayload } from "@/app/help/cancel/actions";

function money(value: unknown) {
  const amount = Number(value ?? 0);
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(Number.isFinite(amount) ? amount : 0);
}

export function StatusCancellation({ token }: { token: string }) {
  const router = useRouter();
  const dialogRef = useRef<HTMLDialogElement>(null);
  const [assessmentState, assessAction, assessing] = useActionState(
    statusCancellationAction.bind(null, token, "assess"),
    {},
  );
  const [confirmState, confirmAction, confirming] = useActionState(
    statusCancellationAction.bind(null, token, "confirm"),
    {},
  );

  useEffect(() => {
    if (assessmentState.data && dialogRef.current && !dialogRef.current.open) {
      dialogRef.current.showModal();
    }
  }, [assessmentState.data]);

  useEffect(() => {
    if (confirmState.ok) {
      if (dialogRef.current?.open) dialogRef.current.close();
      router.refresh();
    }
  }, [confirmState.ok, router]);

  const payload = assessmentState.data as CancellationAssessmentPayload | undefined;
  const assessment = payload?.assessment;
  const progress = payload?.progress;
  const pickup = payload?.pickup_return;

  return (
    <section className="status-cancel">
      {confirmState.ok ? (
        <p className="notice success">
          Your cancellation has been confirmed. ToolTag will email the cancellation details.
        </p>
      ) : (
        <form action={assessAction}>
          <button className="secondary" disabled={assessing}>
            {assessing ? "Checking cancellation options…" : "Cancel Service"}
          </button>
        </form>
      )}

      {assessmentState.error && (
        <p role="alert" className="notice error">
          {assessmentState.error}
        </p>
      )}

      <dialog ref={dialogRef} className="cancel-dialog">
        {assessment && (
          <div className="stack">
            <div>
              <p className="eyebrow">ToolTag · Cancellation Review</p>
              <h2>Cancel {payload.job_code}?</h2>
            </div>

            <div className="panel">
              <p>
                Engraving progress:{" "}
                <strong>
                  {progress?.finished ?? 0}/{progress?.total ?? 0} items finished
                </strong>
              </p>
              {(progress?.started ?? 0) > (progress?.finished ?? 0) && (
                <p className="muted">
                  {progress.started}/{progress.total} items have been started or finished.
                </p>
              )}
              <p>
                Current cancellation rule: <strong>{assessment.rule}</strong>
              </p>
              <p>
                Service cancellation charge:{" "}
                <strong>{assessment.service_charge_percent}%</strong>{" "}
                ({money(assessment.service_charge_amount)})
              </p>
            </div>

            {pickup && Number(assessment.pickup_fee_amount ?? 0) > 0 && (
              <div className={assessment.pickup_fee_refundable ? "notice" : "notice error"}>
                <strong>
                  {assessment.pickup_fee_refundable
                    ? "PICKUP FEE ELIGIBLE FOR REFUND"
                    : "PICKUP FEE: NOT ELIGIBLE FOR A REFUND"}
                </strong>
                <p>
                  Pickup & Return Terms v{pickup.terms_version ?? "2.0"} apply. The Pickup
                  Service Fee becomes non-refundable after the applicable Friday 6:00 PM
                  cancellation deadline or when ToolTag arrives and the scheduled items are
                  unavailable for Pickup.
                </p>
              </div>
            )}

            {Number(assessment.refund_eligible_amount ?? 0) > 0 ? (
              <p className="notice success">
                Eligible refund: <strong>{money(assessment.refund_eligible_amount)}</strong>.
                Approved refunds are generally processed within 5–7 business days after
                ToolTag confirms the refund.
              </p>
            ) : (
              <p className="notice error">
                <strong>NOT ELIGIBLE FOR A REFUND</strong>
                {Number(assessment.amount_due ?? 0) > 0 && (
                  <>
                    <br />
                    Amount due under the accepted cancellation terms:{" "}
                    <strong>{money(assessment.amount_due)}</strong>.
                  </>
                )}
              </p>
            )}

            {!assessment.allowed ? (
              <p className="notice error">
                <strong>THIS JOB CAN NO LONGER BE CANCELLED FOR CONVENIENCE.</strong>
              </p>
            ) : (
              <form action={confirmAction}>
                {confirmState.error && (
                  <p role="alert" className="notice error">
                    {confirmState.error}
                  </p>
                )}
                <button disabled={confirming}>
                  {confirming ? "Cancelling…" : "Yes, Cancel This Service"}
                </button>
              </form>
            )}

            <button
              type="button"
              className="secondary"
              onClick={() => dialogRef.current?.close()}
            >
              Keep Service
            </button>
          </div>
        )}
      </dialog>
    </section>
  );
}
