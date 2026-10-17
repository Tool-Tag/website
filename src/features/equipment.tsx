import {rows} from "@/lib/domain/context";
import {Heading} from "@/components/ui";
import {EquipmentList, type EquipmentRecord} from "@/components/equipment-list";
import {money} from "@/lib/domain/money";

export async function Equipment({expense}: {expense?: string}) {
  const [assets, expenses, categories] = await Promise.all([
    rows("asset_details"), rows("expense_details"), rows("categories"),
  ]);
  const equipment: EquipmentRecord[] = assets.map(asset => ({
    id: asset.id, name: asset.name,
    category: categories.find(category => category.id === asset.category_id)?.name ?? "—",
    serialNumber: asset.serial_number, warrantyExpiration: asset.warranty_expiration,
    origin: asset.origin, status: asset.status, purchaseCost: asset.purchase_cost,
    estimatedValue: asset.estimated_value, expenseId: asset.source_expense_id,
    vendor: asset.vendor, purchaseDate: asset.purchase_date, donatedBy: asset.donated_by,
    receivedDate: asset.received_date, notes: asset.notes, createdAt: asset.created_at,
  }));
  return <>
    <Heading title="Equipment" subtitle="The purchase lives in Finance; linked equipment is managed here."/>
    <EquipmentList assets={equipment} expense={expense}
      categories={categories.filter(category => category.kind === "asset" && category.active).map(category => ({value: category.id, label: category.name}))}
      expenses={expenses.filter(item => item.is_equipment && !item.linked_asset_id).map(item => ({value: item.transaction_id, label: `${item.description} · ${money(item.amount)}`}))}/>
  </>;
}
