import Link from "next/link";
import { rows } from "@/lib/domain/context";
import { Heading, Panel, Table, Empty } from "@/components/ui";
import { AssetForm } from "@/components/asset-form";
import { money } from "@/lib/domain/money";
export async function Equipment({ expense }: { expense?: string }) {
  const [assets, expenses, categories] = await Promise.all([
    rows("asset_details"),
    rows("expense_details"),
    rows("categories"),
  ]);
  return (
    <>
      <Heading
        title="Equipment"
        subtitle="The purchase lives in Finance; linked equipment is managed here."
      />
      <Panel>
        {assets.length ? (
          <Table
            headers={["Equipment", "Source", "Value / Cost", "Purchase", "Status"]}
          >
            {assets.map((a) => (
              <tr key={a.id}>
                <td>
                  {a.name}
                  <br />
                  <small>{a.serial_number}</small>
                </td>
                <td>{a.origin}</td>
                <td>
                  {money(
                    a.origin === "Purchased"
                      ? a.purchase_cost
                      : a.estimated_value,
                  )}
                </td>
                <td>
                  {a.source_expense_id ? (
                    <Link
                      href={`/app/finance/transactions/${a.source_expense_id}`}
                    >
                      {a.purchase_date} · {a.vendor}
                    </Link>
                  ) : (
                    a.received_date
                  )}
                </td>
                <td>{a.status}</td>
              </tr>
            ))}
          </Table>
        ) : (
          <Empty />
        )}
      </Panel>
      <Panel title="Register Equipment">
        <AssetForm
          categories={categories
            .filter((c) => c.kind === "asset")
            .map((c) => ({ value: c.id, label: c.name }))}
          expenses={expenses
            .filter((e) => e.is_equipment && !e.linked_asset_id)
            .map((e) => ({
              value: e.transaction_id,
              label: `${e.description} · ${money(e.amount)}`,
            }))}
          expense={expense}
        />
      </Panel>
    </>
  );
}
