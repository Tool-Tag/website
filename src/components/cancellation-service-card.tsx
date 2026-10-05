"use client";

import { useActionState, useEffect, useRef } from "react";
import {
  secureCancellationAction,
  type SecureCancelState,
} from "@/app/help/cancel/actions";

const initial: SecureCancelState = {};

function currency(value: unknown) {
  const n = Number(value ?? 0);
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(Number.isFinite(n) ? n : 0);
}

export function CancellationServiceCard({
  token,
  service,
}: {
  token: string;
  service: any;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const kind = service.kind === "Quote" ? "Quote" : "Job";

  const [quoteState, quoteAction, quotePending] = useActionState(
    secureCancellationAction.bind(null, token, "quote", String(service.id)),
    initial,
  );
  const [assessmentState, assessmentAction, assessing] = useActionState(
    secureCancellationAction.bind(null, token, "job-assess", String(service.id)),
    initial,
  );
  const [confirmState, confirmAction, confirming] = useActionState(
    secureCancellationAction.bind(null, token, "job-confirm", String(service.id)),
    initial,
  );

  useEffect(() => {
    if (assessmentState.data && !dialog.current?.open) dialog.current?.showModal();
  }, [assessmentState.data]);

  useEffect(() => {
    if (confirmState.ok) dialog.current?.close();
  }, [confirmState.ok]);

  if (quoteState.ok) {
    return (
      <section className="item">
        <strong>{service.code}</strong>
        <p className="notice success">This Quote has been cancelled.</p>
      </section>
    );
  }

  if (confirmState.ok) {
    return (
      <section className="item">
        <strong>{service.code}</strong>
        <p className="notice success">
          This service has been cancelled. ToolTag will send the cancellation details
          and any applicable refund information by email.
        </p>
        {confirmState.data?.status_path && (
          <a className="button" href={confirmState.data.status_path}>
            Open Job Status
          </a>
        )}
      </section>
    );
  }

  const payload = assessmentState.data as any;
  const assessment = payload?.assessment;
  const progress = payload?.progress;
  const pickup = payload?.pickup_return;

  return (
    <section className="item cancellation-service-card">
      <div className="pick-return-row">
        <div>
          <small>{kind}</small>
          <h3>{service.code}</h3>
          <p className="muted">
            {kind === "Job"
              ? String(service.status) + " · " + String(service.work_stage ?? "")
              : String(service.status) + " · " + currency(service.amount)}
          </p>
        </div>

        {kind === "Job" && service.progress && (
          <div className="cancellation-progress">
            <strong>
              {service.progress.finished ?? 0}/{service.progress.total ?? 0}
            </strong>
            <small>items finished</small>
          </div>
        )}
      </div>

      {kind === "Quote" ? (
        <>
          <p className="muted">
            This Quote has not yet become an active production Job. Cancelling it will
            close the Quote.
          </p>
          <form
            action={quoteAction}
            onSubmit={(event) => {
              if (!window.confirm("Cancel " + String(service.code) + "?"))
                event.preventDefault();
            }}
          >
            {quoteState.error && <p className="notice error">{quoteState.error}</p>}
            <button className="secondary" disabled={quotePending}>
              {quotePending ? "Cancelling…" : "Cancel Quote"}
            </button>
          </form>
        </>
      ) : (
        <>
          <form action={assessmentAction}>
            {assessmentState.error && (
              <p className="notice error">{assessmentState.error}</p>
            )}
            <button className="secondary" disabled={assessing}>
              {assessing ? "Checking eligibility…" : "Review Cancellation"}
            </button>
          </form>

          <dialog ref={dialog} className="cancel-dialog">
            {assessment && (
              <div className="stack">
                <div>
                  <p className="eyebrow">ToolTag · Cancellation Review</p>
                  <h2>Cancel {payload.job_code}?</h2>
                </div>

                <section className="panel">
                  <p>
                    Engraving progress:{" "}
                    <strong>
                      {progress?.finished ?? 0}/{progress?.total ?? 0} items finished
                    </strong>
                  </p>
                  {(progress?.started ?? 0) > (progress?.finished ?? 0) && (
                    <p className="muted">
                      {progress.started}/{progress.total} items have been started or
                      finished.
                    </p>
                  )}
                  <p>
                    Cancellation stage: <strong>{assessment.rule}</strong>
                  </p>
                  <p>
                    Service cancellation charge:{" "}
                    <strong>{assessment.service_charge_percent}%</strong>{" "}
                    ({currency(assessment.service_charge_amount)})
                  </p>
                </section>

                {pickup && Number(assessment.pickup_fee_amount ?? 0) > 0 && (
                  <section
                    className={
                      assessment.pickup_fee_refundable ? "notice" : "notice error"
                    }
                  >
                    <strong>
                      {assessment.pickup_fee_refundable
                        ? "PICKUP FEE ELIGIBLE FOR REFUND"
                        : "PICKUP FEE: NOT ELIGIBLE FOR A REFUND"}
                    </strong>
                    <p>
                      Pickup & Return Terms v{pickup.terms_version ?? "2.0"} apply.
                      The Pickup Service Fee is non-refundable after the applicable
                      Friday 6:00 PM cancellation deadline or if ToolTag arrives and
                      the scheduled items are unavailable for Pickup.
                    </p>
                  </section>
                )}

                {Number(assessment.refund_eligible_amount ?? 0) > 0 ? (
                  <section className="notice success">
                    Eligible refund:{" "}
                    <strong>{currency(assessment.refund_eligible_amount)}</strong>.
                    Approved refunds are generally processed within 5–7 business days
                    after ToolTag confirms the refund.
                  </section>
                ) : (
                  <section className="notice error">
                    <strong>NOT ELIGIBLE FOR A REFUND</strong>
                    {Number(assessment.amount_due ?? 0) > 0 && (
                      <p>
                        Amount due under the accepted cancellation terms:{" "}
                        <strong>{currency(assessment.amount_due)}</strong>.
                      </p>
                    )}
                  </section>
                )}

                {!assessment.allowed ? (
                  <p className="notice error">
                    <strong>
                      THIS JOB CAN NO LONGER BE CANCELLED FOR CONVENIENCE.
                    </strong>
                  </p>
                ) : (
                  <form action={confirmAction}>
                    {confirmState.error && (
                      <p className="notice error">{confirmState.error}</p>
                    )}
                    <button disabled={confirming}>
                      {confirming ? "Cancelling…" : "Yes, Cancel This Service"}
                    </button>
                  </form>
                )}

                <button
                  type="button"
                  className="secondary"
                  onClick={() => dialog.current?.close()}
                >
                  Keep Service
                </button>
              </div>
            )}
          </dialog>
        </>
      )}
    </section>
  );
}
