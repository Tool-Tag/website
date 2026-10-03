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
        subtitle="Una cuenta bancaria física. Asignaciones separadas por unidad."
      />
      <div className="grid">
        <Panel title="BOFT System">
          {settings[0]?.boft_url ? (
            <a className="button secondary" href={settings[0].boft_url}>
              Abrir BOFT ↗
            </a>
          ) : (
            <p className="muted">Configura el enlace en Settings.</p>
          )}
          <p className="muted" style={{ marginTop: 14 }}>
            BOFT sigue en su sistema actual. Sus datos históricos aún no están
            migrados.
          </p>
        </Panel>
        <Panel title="ToolTag Finance">
          <Link className="button" href="/app/finance">
            Abrir ToolTag →
          </Link>
        </Panel>
        <Metric
          label="BOFT Business Checking · saldo físico"
          value={bank?.reconciled_balance ?? "Pendiente de conciliación"}
          currency={bank?.reconciled_balance != null}
          help="Se muestra una sola vez. No se conoce el saldo real del banco hasta conciliarlo."
        />
      </div>
      <Panel title="Asignación y resultados por unidad">
        <Table headers={["Unidad", "Cuenta operativa", "Resultado registrado"]}>
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
          <Table headers={["Unidad", "Fecha", "Descripción", "Importe"]}>
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
