import Link from "next/link";
import { context } from "@/lib/domain/context";
import { Heading, Panel, Empty, Badge } from "@/components/ui";
import { Form } from "@/components/form";

export const dynamic = "force-dynamic";

type RequestedMark = {
  type?: string;
  location?: string;
  text?: string;
  description?: string;
};

type RequestedItem = {
  article?: string;
  brand?: string;
  model?: string;
  quantity?: number;
  marks?: RequestedMark[];
  notes?: string;
};

type CustomerCandidate = {
  id: string;
  name: string;
  email: string;
  phone: string;
};

export default async function GetTaggedRequestDetail({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const { db } = await context();
  const { data: request, error } = await db.rpc("get_get_tagged_request", {
    p_id: id,
  });

  if (error || !request) return <Empty>Get Tagged request not found.</Empty>;

  const details = request.details ?? {};
  const contact = details.contact ?? {};
  const service = details.service ?? {};
  const items = (Array.isArray(details.items)
    ? details.items
    : Array.isArray(details.quote_items)
      ? details.quote_items
      : []) as RequestedItem[];
  const candidates = (
    Array.isArray(request.candidates) ? request.candidates : []
  ) as CustomerCandidate[];

  return (
    <>
      <Heading
        title={request.reference}
        subtitle="Get Tagged public request"
      >
        <Badge>{request.request_status}</Badge>
      </Heading>

      <div className="grid two">
        <Panel title="Customer">
          <p><strong>{contact.name || "—"}</strong></p>
          <p>{contact.email || "—"}</p>
          <p>{contact.phone || "—"}</p>
          {contact.company_name && <p className="muted">{contact.company_name}</p>}
        </Panel>

        <Panel title="Service">
          <p><strong>{service.method || "Not selected"}</strong></p>
          {service.address && <p>{service.address}</p>}
          {details.notes && <p className="muted">{details.notes}</p>}
        </Panel>
      </div>

      <Panel title="Requested items">
        <div className="stack">
          {items.map((item, index) => (
            <div className="item" key={index}>
              <div className="pick-return-row">
                <div>
                  <strong>{item.article || "Item"}</strong>
                  <p className="muted">
                    {[item.brand, item.model].filter(Boolean).join(" · ")}
                  </p>
                </div>
                <Badge>Qty {item.quantity ?? 1}</Badge>
              </div>
              {Array.isArray(item.marks) && item.marks.length > 0 && (
                <div className="stack">
                  {item.marks.map((mark, markIndex) => (
                    <div key={markIndex}>
                      <strong>{mark.type}</strong> · {mark.location || "Location not provided"}
                      {mark.text && <p>{mark.text}</p>}
                      {mark.description && <p className="muted">{mark.description}</p>}
                    </div>
                  ))}
                </div>
              )}
              {item.notes && <p className="muted">{item.notes}</p>}
            </div>
          ))}
        </div>
      </Panel>

      {request.request_status === "Pending" && (
        <div className="grid two">
          {candidates.length > 0 ? (
            <Panel title="Approve Request">
              <div className="notice">
                {candidates.length === 1
                  ? "One existing Customer matches this request. ToolTag will reuse that Customer."
                  : "Multiple Customers match this request. Select the correct Customer before approving."}
              </div>

              <Form
                operation="get-tagged-approve"
                hidden={{ id }}
                back="/app/get-tagged"
                fields={
                  candidates.length > 1
                    ? [
                        {
                          name: "customer_id",
                          label: "Existing Customer",
                          required: true,
                          options: candidates.map((candidate) => ({
                            value: candidate.id,
                            label: `${candidate.name} · ${candidate.email} · ${candidate.phone}`,
                          })),
                        },
                      ]
                    : []
                }
                button="Approve Request & Create Quote Draft"
              />
            </Panel>
          ) : (
            <Form
              operation="get-tagged-approve"
              hidden={{ id }}
              back="/app/get-tagged"
              fields={[]}
              button="Approve Request & Create Quote Draft"
            />
          )}

          <Panel title="Reject Request">
            <Form
              operation="get-tagged-reject"
              hidden={{ id }}
              back="/app/get-tagged"
              fields={[
                {
                  name: "reason",
                  label: "Reason",
                  type: "textarea",
                  wide: true,
                },
              ]}
              button="Reject Request"
            />
          </Panel>
        </div>
      )}

      {request.quote_id && (
        <Link className="button" href={`/app/quotes/${request.quote_id}`}>
          Open Quote
        </Link>
      )}
    </>
  );
}
