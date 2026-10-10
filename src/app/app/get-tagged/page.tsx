import {denverDateTime} from "@/lib/domain/time";
import Link from "next/link";
import { context } from "@/lib/domain/context";
import { Heading, Panel, Empty, Badge } from "@/components/ui";

export const dynamic = "force-dynamic";

type GetTaggedAttentionRow = {
  id: string;
  reference: string;
  name: string;
  service_method?: string | null;
  created_at: string;
  request_status: string;
  matching: string;
};

export default async function GetTaggedRequestsPage() {
  const { db } = await context();
  const { data, error } = await db.rpc("get_tagged_attention");

  if (error) {
    return (
      <>
        <Heading title="Get Tagged Requests" />
        <p className="notice error">{error.message}</p>
      </>
    );
  }

  const requests = (Array.isArray(data) ? data : []) as GetTaggedAttentionRow[];

  return (
    <>
      <Heading
        title="Get Tagged Requests"
        subtitle="Review public requests before a Customer and Quote are created."
      />

      {requests.length ? (
        <div className="stack">
          {requests.map((request) => (
            <Panel key={request.id}>
              <div className="pick-return-row">
                <div>
                  <p className="eyebrow">{request.reference}</p>
                  <h2>{request.name}</h2>
                  <p className="muted">
                    {request.service_method || "Service method not selected"} ·{" "}
                    {denverDateTime(request.created_at)}
                  </p>
                </div>
                <div className="actions">
                  <Badge>{request.request_status}</Badge>
                  <Badge>{request.matching}</Badge>
                </div>
              </div>

              <Link className="button" href={`/app/get-tagged/${request.id}`}>
                Review Request
              </Link>
            </Panel>
          ))}
        </div>
      ) : (
        <Empty>No Get Tagged requests need attention.</Empty>
      )}
    </>
  );
}
