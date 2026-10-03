import { supabase } from "@/lib/supabase/server";
import { Panel, Table } from "@/components/ui";
import { AcceptForm } from "@/components/accept-form";
import { money } from "@/lib/domain/money";
export const dynamic = "force-dynamic";
export default async function Accept({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const db = await supabase();
  const { data: q, error } = await db.rpc("public_quote", { p_token: token });
  if (error || !q)
    return (
      <main className="public">
        <h1>This link is unavailable.</h1>
        <p>It may have expired or been replaced. Please contact ToolTag.</p>
      </main>
    );
  return (
    <main className="public">
      <p className="eyebrow">ToolTag · Your Tools. Your Mark.</p>
      <h1>{q.code}</h1>
      <p className="muted">
        For {q.customer_name} · Version {q.revision}
      </p>
      <Panel>
        <Table headers={["Item", "Details", "Qty", "Unit price"]}>
          {q.items.map(
            (i: {
              id: string;
              article: string;
              engraving_type: string;
              engraving_text: string;
              quantity: number;
              unit_price: string;
              width_mm: string;
              height_mm: string;
              notes: string;
              paint_fill: boolean;
              colors: number;
            }) => (
              <tr key={i.id}>
                <td>{i.article}</td>
                <td>
                  {i.engraving_type}
                  <br />
                  {i.engraving_text}
                  <br />
                  {i.width_mm && `${i.width_mm} × ${i.height_mm ?? "—"} mm`}
                  <br />
                  {i.paint_fill && `Paint fill · ${i.colors} colors`}
                  <br />
                  {i.notes}
                </td>
                <td>{i.quantity}</td>
                <td>{money(i.unit_price)}</td>
              </tr>
            ),
          )}
        </Table>
        <h2 style={{ marginTop: 20 }}>Total: {money(q.total)}</h2>
        <p>{q.notes}</p>
      </Panel>
      {q.accepted ? (
        <div className="notice success">
          Your quote and agreement are accepted. ToolTag has created your job.
        </div>
      ) : q.status === "Agreement Pending" ? (
        <Panel title={`${q.policy.title} · v${q.policy.version}`}>
          <div className="policy">{q.policy.content}</div>
          <p>The exact text above will be preserved with your acceptance.</p>
          <AcceptForm key="agreement" token={token} kind="agreement" />
        </Panel>
      ) : (
        <Panel title="Review your quote">
          <AcceptForm key="quote" token={token} kind="quote" />
        </Panel>
      )}
      <footer className="footer">
        ToolTag is a registered DBA of Bandits of the Framing LLC.
      </footer>
    </main>
  );
}
