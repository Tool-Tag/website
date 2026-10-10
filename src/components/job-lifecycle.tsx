import {denverDateTime} from "@/lib/domain/time";
import Link from "next/link";
import { cache } from "react";
import { randomUUID } from "node:crypto";
import { context, rows } from "@/lib/domain/context";
import { Panel } from "./ui";
import { Form } from "./form";
import { money } from "@/lib/domain/money";
import { extensionStatusLabel, paymentStatusLabel } from "@/lib/domain/status-labels";

type JobLifecycleSection = "customer" | "commercial" | "delivery" | "activity";

const getLifecycleData = cache(async (id: string) => {
  const { db, role } = await context();
  const [extensions, totals, ack, receipts, paymentRequests, activity, { data: lifecycle }] =
    await Promise.all([
      rows("job_extensions", { field: "job_id", value: id, order: "sequence" }),
      rows("job_commercial_totals", { id }),
      rows("delivery_acknowledgments", { field: "job_id", value: id }),
      rows("job_receipts", { field: "job_id", value: id, order: "created_at" }),
      rows("payment_requests", { field: "job_id", value: id, order: "submitted_at" }),
      rows("audit_log", { field: "entity_id", value: id, order: "created_at", limit: 20 }),
      db.rpc("job_lifecycle", { p_job: id }),
    ]);

  return {
    role,
    extensions,
    totals,
    ack,
    receipts,
    paymentRequests,
    activity,
    lifecycle,
  };
});

export async function JobLifecycle({
  id,
  section,
}: {
  id: string;
  section: JobLifecycleSection;
}) {
  const { role, extensions, totals, ack, receipts, paymentRequests, activity, lifecycle } =
    await getLifecycleData(id);
  const t = totals[0];

  if (section === "customer") {
    return lifecycle?.customer ? (
      <Panel title="Customer">
        <p>
          {lifecycle.customer.name} · {lifecycle.customer.email}
        </p>
      </Panel>
    ) : null;
  }

  if (section === "commercial") {
    const proofLinks = new Map<string, string>();
    if (role === "admin") {
      const { db } = await context();
      await Promise.all(
        paymentRequests
          .filter((request) => request.proof_path)
          .map(async (request) => {
            const { data } = await db.storage
              .from("payment-proofs")
              .createSignedUrl(request.proof_path, 3600);
            if (data?.signedUrl) proofLinks.set(request.id, data.signedUrl);
          }),
      );
    }

    return (
      <>
        <Panel title="Job Extensions">
          {extensions.map((x) => (
            <p key={x.id}>
              <Link href={`/app/job-extensions/${x.id}`}>{x.code}</Link> · {extensionStatusLabel(x.status)} ·{" "}
              {money(x.total)}
            </p>
          ))}
          {!extensions.length && <p>Sin ampliaciones.</p>}
          {role === "admin" && (
            <details>
              <summary>Add Additional Work Request</summary>
              <Form
                operation="request-extension"
                hidden={{ job_id: id, request_key: randomUUID() }}
                fields={[
                  {
                    name: "request",
                    label: "Requested Work",
                    type: "textarea",
                    required: true,
                  },
                ]}
                button="Create Extension"
                back={`/app/jobs/${id}`}
              />
            </details>
          )}
        </Panel>

        {t && (
          <Panel title="Totals & Payments">
            <p>Base Quote: {money(t.base_amount)}</p>
            <p>Approved extensions: {money(t.extensions_amount)}</p>
            <h3>Total: {money(t.grand_total)}</h3>
            <p>
              Collected: {money(t.collected)} · Refunded: {money(t.refunded)} · Balance:{" "}
              {money(t.balance_due)}
            </p>
            <p className="muted">
              Each approved extension has its own sale component and collections. Here they
              consolidate without duplicating revenue.
            </p>
            {extensions
              .filter((x) => x.sale_id)
              .map((x) => (
                <p key={x.id}>
                  <Link href={`/app/finance/sales/${x.sale_id}`}>
                    Record Collection for {x.code}
                  </Link>
                </p>
              ))}
          </Panel>
        )}

        <Panel title="Customer Payments">
          {paymentRequests.length ? (
            paymentRequests.map((request) => (
              <div className="item" key={request.id}>
                <p>
                  <strong>{request.method}</strong> · {money(request.amount)} · {paymentStatusLabel(request.status)}
                </p>
                <p className="muted">
                  {request.purpose || "Customer Payment"} · Submitted:{" "}
                  {denverDateTime(request.submitted_at)}
                </p>
                {proofLinks.get(request.id) && (
                  <p>
                    <a
                      href={proofLinks.get(request.id)}
                      target="_blank"
                      rel="noreferrer"
                    >
                      View Receipt →
                    </a>
                  </p>
                )}
                {request.status === "Confirmed" && (
                  <p>
                    Confirmed: {money(request.confirmed_amount)} ·{" "}
                    {request.confirmed_at
                      ? denverDateTime(request.confirmed_at)
                      : ""}
                  </p>
                )}
                {role === "admin" && request.status === "Pending Verification" && (
                  <Form
                    operation="confirm-payment"
                    hidden={{ id: request.id }}
                    fields={[]}
                    button="Confirm Payment Received"
                    back={`/app/jobs/${id}`}
                  />
                )}
              </div>
            ))
          ) : (
            <p>No customer payments submitted.</p>
          )}
        </Panel>

        <Panel title="Job Receipts">
          {receipts.map((r) => (
            <p key={r.id}>
              <Link href={`/app/job-receipts/${r.id}`}>
                Summary from {denverDateTime(r.created_at)}
              </Link>{" "}
              · {r.storage_status}
            </p>
          ))}
          {role === "admin" && (
            <Form
              operation="generate-receipt"
              hidden={{ job_id: id }}
              fields={[]}
              button="Generate & Send Payment Summary"
              back={`/app/jobs/${id}`}
            />
          )}
        </Panel>
      </>
    );
  }

  if (section === "delivery") {
    return (
      <Panel title="Customer Review & Delivery">
        <p>
          Response:{" "}
          {lifecycle?.review?.response === "ready"
            ? "Ready for Delivery"
            : lifecycle?.review?.response === "additional"
              ? "Requested Additional Work"
              : "Pending"}
        </p>
        {lifecycle?.review?.customer_request && <p>{lifecycle.review.customer_request}</p>}
        <p>
          Review email: {lifecycle?.review?.notified_at || "Pending"}
          <br />
          First visit: {lifecycle?.review?.viewed_at || "Pending"}
          <br />
          Respuesta: {lifecycle?.review?.response_at || "Pending"}
        </p>
        {lifecycle?.review_path && (
          <Link href={lifecycle.review_path} target="_blank" rel="noreferrer">
            Open Private Review
          </Link>
        )}
        <p>
          Receipt confirmed:{" "}
          {ack[0]
            ? denverDateTime(ack[0].acknowledged_at)
            : "No explicit confirmation"}
        </p>
      </Panel>
    );
  }

  return (
    <Panel title="Activity">
      {activity.length ? (
        activity.map((a) => (
          <p key={a.id}>
            {denverDateTime(a.created_at)} · {a.field} ·{" "}
            {typeof a.new_value === "string" ? a.new_value : JSON.stringify(a.new_value)}
          </p>
        ))
      ) : (
        <p>No activity recorded.</p>
      )}
    </Panel>
  );
}
