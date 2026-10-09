import { AcceptedDocuments } from "@/components/accepted-documents";
import Link from "next/link";
import { rows, context } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty, Badge } from "@/components/ui";
import { SendQuote } from "@/components/send-quote";
import { QuoteScope } from "@/components/quote-scope";
import { QuoteBuilder } from "@/components/quote-builder";
import { QuoteTabs } from "@/components/quote-tabs";
import { money, quoteTotal } from "@/lib/domain/money";
import { quoteStatusLabel } from "@/lib/domain/status-labels";
export async function Quotes({
  id,
  customer,
  revise,
}: {
  id?: string;
  customer?: string;
  revise?: string;
}) {
  if (id === "new") {
    const customers = await rows("customers");
    const original = revise ? (await rows("quotes", { id: revise }))[0] : null;
    const originalFlow = original
      ? (await rows("commercial_flows", { id: original.flow_id }))[0]
      : null;
    const items = original
      ? await rows("quote_items", { field: "quote_id", value: original.id })
      : undefined;
    return (
      <>
        <Heading
          title={revise ? "Review Quote" : "New Quote"}
          subtitle="Each revision preserves what the customer previously approved."
        />
        <Panel>
          {customers.length ? (
            <QuoteBuilder
              customers={customers.map((c) => ({ id: c.id, name: c.name }))}
              customer={originalFlow?.customer_id ?? customer}
              revises={revise}
              notes={original?.notes ?? ""}
              initial={items?.map((i) => ({
                marks: i.marks,
                paint_details: i.paint_details?.mode
                  ? i.paint_details
                  : undefined,
                adaptation_fee: i.adaptation_fee,
                paint_fee: i.paint_fee,
                additional_engraving_fee: i.additional_engraving_fee,
                article: i.article,
                quantity: i.quantity,
                engraving_type: i.engraving_type,
                engraving_text: i.engraving_text ?? "",
                width_mm: String(i.width_mm ?? ""),
                height_mm: String(i.height_mm ?? ""),
                paint_fill: i.paint_fill,
                colors: i.colors,
                unit_price: String(i.unit_price),
                notes: i.notes ?? "",
              }))}
            />
          ) : (
            <Empty>
              <Link href="/app/customers/new">Add a Customer first →</Link>
            </Empty>
          )}
        </Panel>
      </>
    );
  }
  if (id) {
    const q = (await rows("quotes", { id }))[0];
    if (!q) return <Empty>Quote not found.</Empty>;
    const flow = (await rows("commercial_flows", { id: q.flow_id }))[0];
    const contact = flow ? (await rows("customers", { id: flow.customer_id }))[0] : null;
    const {db}=await context();
    const delivery=q.sent_at ? (await db.rpc("quote_delivery",{p_id:id})).data : null;
    const quoteMail = await db.from("notifications").select("created_at,mail_attempted_at,status").eq("entity_id",id).eq("event","Quote Sent").order("created_at",{ascending:false}).limit(1);
    const latestMail = quoteMail.data?.[0];
    const items = await rows("quote_items", { field: "quote_id", value: id });
    const jobs = await rows("jobs", { field: "flow_id", value: q.flow_id });
    const needsIntakeReview =
      q.source === "public_get_tagged" &&
      q.status === "Draft" &&
      !q.intake_reviewed_at;
    const intake = q.intake_details ?? {};
    const service = intake.service ?? {};
    return (
      <>
        <Heading title={q.code} subtitle={`Version ${q.revision}`}>
          <Badge>{quoteStatusLabel(q.status)}</Badge>
          <Link
            className="button secondary"
            href={`/app/quotes/new?revise=${q.id}`}
          >
            Create Revision
          </Link>
        </Heading>
        {needsIntakeReview ? (
          <>
            <Panel title="Review Get Tagged Request">
              <div className="grid two">
                <div>
                  <small>Customer</small>
                  <p><strong>{contact?.name ?? "—"}</strong></p>
                  <p className="muted">
                    {contact?.email ?? "—"} · {contact?.phone ?? "—"}
                  </p>
                </div>
                <div>
                  <small>Service</small>
                  <p><strong>{service.method ?? "Not selected"}</strong></p>
                  {service.address && <p className="muted">{service.address}</p>}
                </div>
              </div>

              {service.method === "Pickup" && (
                <div className="notice">
                  Pickup & Return · Agreement v{service.agreement_version ?? 2} ·
                  Pickup Service Fee ${Number(service.pickup_fee ?? 10).toFixed(2)}
                  <br />
                  The Agreement version shown to the customer with this Request is
                  frozen on the Quote when you approve the Request.
                </div>
              )}

              <p className="muted">
                Review every item and mark, set the base service price for each
                production item, and adjust notes if needed. Automatic engraving,
                paint-fill, logo-preparation, and Pickup fees are recalculated when
                you complete this review.
              </p>
            </Panel>

            {contact ? (
              <Panel title="Price & Review">
                <QuoteBuilder
                  customers={[{ id: contact.id, name: contact.name }]}
                  customer={contact.id}
                  getTaggedQuoteId={id}
                  notes={q.notes ?? ""}
                  initial={items
                    .filter((i) => i.pricing?.kind !== "pickup_service_fee")
                    .map((i) => ({
                    marks: i.marks,
                    paint_details: i.paint_details?.mode
                      ? i.paint_details
                      : undefined,
                    adaptation_fee: i.adaptation_fee,
                    paint_fee: i.paint_fee,
                    additional_engraving_fee: i.additional_engraving_fee,
                    article: i.article,
                    quantity: i.quantity,
                    engraving_type: i.engraving_type,
                    engraving_text: i.engraving_text ?? "",
                    width_mm: String(i.width_mm ?? ""),
                    height_mm: String(i.height_mm ?? ""),
                    paint_fill: i.paint_fill,
                    colors: i.colors,
                    unit_price: String(i.unit_price),
                    notes: i.notes ?? "",
                  }))}
                />
              </Panel>
            ) : (
              <p className="notice error">
                Customer record is missing. Resolve the Request before pricing.
              </p>
            )}
          </>
        ) : (
          <Panel title="Quote Scope">
            <QuoteScope items={items} />
            <h2 style={{ marginTop: 20 }}>
              Total:{" "}
              {money(
                quoteTotal(
                  items.map((i) => ({
                    quantity: i.quantity,
                    unit_price: String(i.unit_price),
                  })),
                ),
              )}
            </h2>
            <p>{q.notes}</p>
          </Panel>
        )}

        {!needsIntakeReview && ["Draft", "Sent", "Viewed"].includes(q.status) && (
          <Panel title="Share with Customer">
            <p className="muted">
              Send the customer a private link to review the Quote and Agreement.
              The link is valid for 7 days from the first send. The selected
              recipient is locked for this revision.
            </p>
            <SendQuote id={id} sent={Boolean(q.sent_at)} lastRequestedAt={latestMail?.mail_attempted_at || latestMail?.created_at || q.sent_at} email={delivery?.recipient || contact?.email} companyEmail={delivery?.recipient ? undefined : contact?.company_email} />
          </Panel>
        )}
        <AcceptedDocuments quoteId={id} />
        {q.status === "Accepted" && (
          <p>
            <Link href={`/app/quotes/${id}/email`}>
              Confirmation Preview
            </Link>
          </p>
        )}
        {jobs.map((j) => (
          <Panel key={j.id}>
            <Link href={`/app/jobs/${j.id}`}>Open {j.code} →</Link>
          </Panel>
        ))}
      </>
    );
  }
  const [list, jobs] = await Promise.all([
    rows("quotes", { order: "created_at" }),
    rows("jobs", { order: "created_at" }),
  ]);

  const jobByQuote = new Map(jobs.map((job) => [job.quote_id, job]));
  const hasClosedJob = (quoteId: string) => {
    const job = jobByQuote.get(quoteId);
    return Boolean(job && (job.work_stage === "Closed" || job.status === "Cancelled"));
  };

  const activeQuotes = list.filter((q) =>
    ["Sent", "Viewed", "Agreement Pending"].includes(q.status),
  );
  const draftQuotes = list.filter((q) => q.status === "Draft");
  const acceptedQuotes = list.filter(
    (q) => q.status === "Accepted" && !hasClosedJob(q.id),
  );
  const historyQuotes = list.filter(
    (q) =>
      ["Declined", "Expired", "Revised"].includes(q.status) ||
      (q.status === "Accepted" && hasClosedJob(q.id)),
  );

  const quoteTable = (
    quotes: typeof list,
    empty: string,
    completedLabel = false,
  ) => (
    <Panel>
      {quotes.length ? (
        <Table headers={["Quote", "Version", "Status", "Validity"]}>
          {quotes.map((q) => {
            const displayStatus =
              completedLabel && q.status === "Accepted" && hasClosedJob(q.id)
                ? "Completed"
                : quoteStatusLabel(q.status);

            return (
              <tr key={q.id}>
                <td>
                  <Link href={`/app/quotes/${q.id}`}>{q.code}</Link>
                </td>
                <td>{q.revision}</td>
                <td>
                  <Badge>{displayStatus}</Badge>
                </td>
                <td>
                  {q.expires_at
                    ? new Date(q.expires_at).toLocaleDateString("en-US")
                    : q.status === "Draft"
                      ? "Not Sent"
                      : "—"}
                </td>
              </tr>
            );
          })}
        </Table>
      ) : (
        <Empty>{empty}</Empty>
      )}
    </Panel>
  );

  return (
    <>
      <Heading
        title="Quotes"
        subtitle="Organized by commercial stage."
      >
        <Link className="button" href="/app/quotes/new">
          + New Quote
        </Link>
      </Heading>

      <QuoteTabs
        defaultTab="active"
        tabs={[
          {
            id: "active",
            label: "Active",
            count: activeQuotes.length,
            content: quoteTable(activeQuotes, "No active Quotes."),
          },
          {
            id: "drafts",
            label: "Drafts",
            count: draftQuotes.length,
            content: quoteTable(draftQuotes, "No Drafts."),
          },
          {
            id: "accepted",
            label: "Accepted",
            count: acceptedQuotes.length,
            content: quoteTable(
              acceptedQuotes,
              "No accepted Quotes.",
            ),
          },
          {
            id: "history",
            label: "History",
            count: historyQuotes.length,
            content: quoteTable(
              historyQuotes,
              "No Quotes in history.",
              true,
            ),
          },
        ]}
      />
    </>
  );
}
