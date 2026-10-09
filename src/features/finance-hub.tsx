import Link from "next/link";
import { rows } from "@/lib/domain/context";
import { Heading, Panel, Metric, Table, Empty } from "@/components/ui";
import { money } from "@/lib/domain/money";
export async function FinanceHub() {
  const [summaries, physical, tx, settings] = await Promise.all([
    rows("finance_summary", { unit: false }),
    rows("physical_accounts", { unit: false }),
    rows("transactions", { unit: false, order: "transaction_date", limit: 20 }),
    rows("unit_settings"),
  ]);
  const bank = physical[0];
  return (
    <>
      <Heading
        title="Finance Hub"
        subtitle="One physical bank account. Separate allocations by business unit."
      />
      <div className="grid">
        <Panel title="BOFT System">
          {settings[0]?.boft_url ? (
            <a className="button secondary" href={settings[0].boft_url}>
              Open BOFT ↗
            </a>
          ) : (
            <p className="muted">Configura el enlace en Settings.</p>
          )}
          <p className="muted" style={{ marginTop: 14 }}>
            BOFT remains in its current system. Its historical data is not yet
            migrados.
          </p>
        </Panel>
        <Panel title="ToolTag Finance">
          <Link className="button" href="/app/finance">
            Open ToolTag →
          </Link>
        </Panel>
        <Metric
          label="BOFT Business Checking · Physical Balance"
          value={bank?.reconciled_balance ?? "Pending Reconciliation"}
          currency={bank?.reconciled_balance != null}
          help="Shown once. The actual bank balance is unknown until reconciliation."
        />
      </div>
      <Panel title="Allocation & Results by Business Unit">
        <Table headers={["Business Unit", "Operating Account", "Recorded Result"]}>
          {summaries.map((s) => (
            <tr key={s.unit_id}>
              <td>{s.code}</td>
              <td>
                {s.code === "TOOLTAG" ? "ToolTag" : "BOFT"} Operating Account ·{" "}
                {money(s.operating_balance)}
              </td>
              <td>{money(s.net_profit)}</td>
            </tr>
          ))}
        </Table>
        <p className="muted">
          Los ceros de BOFT representan ausencia de movimientos migrados, no el
          estado real de BOFT.
        </p>
      </Panel>
      <Panel title="Movimientos recientes">
        {tx.length ? (
          <Table headers={["Business Unit", "Date", "Description", "Amount"]}>
            {tx.map((t) => (
              <tr key={t.id}>
                <td>{summaries.find((s) => s.unit_id === t.unit_id)?.code}</td>
                <td>{t.transaction_date}</td>
                <td>{t.description}</td>
                <td>{money(t.amount)}</td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty />
        )}
      </Panel>
    </>
  );
}
