import Link from "next/link";
import { QuoteScope } from "@/components/quote-scope";
import type { QuoteItem } from "@/lib/domain/quote-items";
import { supabase } from "@/lib/supabase/server";
import { AcceptForm } from "@/components/accept-form";

export const dynamic = "force-dynamic";

export default async function Completion({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data: j, error } = await db.rpc("public_completion", {
    p_token: token,
  });

  if (error || !j)
    return (
      <main className="public">
        <h1>This link is unavailable.</h1>
      </main>
    );

  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Delivery</p>
      <h1>{j.code}</h1>

      {j.original_quote && <QuoteScope items={j.original_quote.items} />}

      {j.extensions?.map((x: { code: string; items: QuoteItem[] }) => (
        <section key={x.code}>
          <h2>{x.code}</h2>
          <QuoteScope items={x.items} />
        </section>
      ))}

      {j.status === "Delivered – Pending Customer Acceptance" ? (
        <>
          <section className="panel">
            <h2>Accept Delivery</h2>
            <p>
              I confirm that I received the items/work associated with this ToolTag Job
              and that the delivered work matches the approved scope.
            </p>
            <p className="muted">
              Delivery acceptance is separate from payment and does not waive your legal rights.
            </p>
            <div className="grid two">
              <AcceptForm token={token} kind="accept" />
              <AcceptForm token={token} kind="issue" />
            </div>
          </section>
        </>
      ) : j.acknowledgment ? (
        <section className="panel">
          <p className="notice success">Delivery accepted.</p>
          <p>Continue to the separate payment step.</p>
          <Link className="button" href={`/payment/${token}`}>
            Continue to Payment
          </Link>
        </section>
      ) : (
        <p className="notice">{j.reason ?? j.status}</p>
      )}
    </main>
  );
}
