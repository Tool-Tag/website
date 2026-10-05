import { CancellationAction } from "@/components/cancellation-action";
import { supabase } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type CancellationService = {
  kind: "Job" | "Quote";
  id: string;
  code: string;
  status: string;
  work_stage?: string;
  progress?: {
    total?: number;
    started?: number;
    finished?: number;
  };
  assessment?: {
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
};

export default async function CancellationServicesPage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data, error } = await db.rpc("cancellation_access", {
    p_token: token,
  });

  if (error || !data) {
    return (
      <main className="public">
        <p className="eyebrow">ToolTag · Cancellation</p>
        <h1>This cancellation link is unavailable.</h1>
      </main>
    );
  }

  const services = (
    Array.isArray(data.services) ? data.services : []
  ) as CancellationService[];

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Cancellation</p>
      <h1>Active services</h1>
      {data.customer_name && <p className="muted">{data.customer_name}</p>}

      {!services.length && (
        <section className="panel">
          <p>No active ToolTag services are available for cancellation.</p>
        </section>
      )}

      {services.map((service) => (
        <section className="panel" key={`${service.kind}-${service.id}`}>
          <h2>{service.code}</h2>
          <p>
            {service.kind} · {service.status}
          </p>

          {service.kind === "Job" && service.progress && (
            <p className="muted">
              Engraving: {service.progress.started ?? 0}/
              {service.progress.total ?? 0} items started ·{" "}
              {service.progress.finished ?? 0}/{service.progress.total ?? 0} Finished
            </p>
          )}

          <CancellationAction
            token={token}
            kind={service.kind === "Job" ? "cancel-job" : "cancel-quote"}
            id={service.id}
            code={service.code}
            assessment={service.kind === "Job" ? service.assessment : null}
          />
        </section>
      ))}
    </main>
  );
}
