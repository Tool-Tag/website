"use client";
import { useState } from "react";
import { Form, type Field } from "./form";
type Option = { value: string; label: string };
export function MovementForm({
  requestId,
  accounts,
  categories,
  sales,
  expenses,
  collections,
  destinationAccounts,
  defaultType = "EXPENSE",
  saleId,
  vendors,
}: {
  requestId: string;
  accounts: Option[];
  categories: Option[];
  sales: Option[];
  expenses: Option[];
  collections: Option[];
  destinationAccounts: Option[];
  defaultType?: string;
  saleId?: string;
  vendors: string[];
}) {
  const [type, setType] = useState(defaultType);
  const [subtype, setSubtype] = useState("Personal Draw");
  const [paidBy, setPaidBy] = useState("Business");
  const today = new Date().toLocaleDateString("en-CA");
  const fields: Field[] = [
    { name: "amount", label: "Importe (USD)", type: "number", required: true },
    {
      name: "transaction_date",
      label: "Transaction date",
      type: "date",
      value: today,
      required: true,
    },
    {
      name: "account_id",
      label: "Allocated account",
      options: accounts,
      required: true,
      value: accounts[0]?.value,
    },
    { name: "description", label: "Description / purpose", required: true },
  ];
  if (type === "EXPENSE")
    fields.push(
      {
        name: "category_id",
        label: "Category",
        options: categories,
        required: true,
      },
      {
        name: "vendor",
        label: "Proveedor — elegir o escribir uno nuevo",
        required: true,
        suggestions: vendors,
      },
      {
        name: "lodging",
        label: "Lodging?",
        value: "false",
        options: [
          { value: "false", label: "No" },
          { value: "true", label: "Yes: receipt always required" },
        ],
      },
    );
  if (type === "COLLECTION" && !saleId)
    fields.push({
      name: "sale_id",
      label: "Sale (blank = unlinked collection for review)",
      options: sales,
    });
  if (type === "COLLECTION")
    fields.push({
      name: "payment_method",
      label: "Payment method",
      required: true,
      options: ["Cash", "Zelle", "Venmo"].map((value) => ({
        value,
        label: value,
      })),
    });
  if (type === "REFUND")
    fields.push({
      name: "original_id",
      label: "Original collection or expense",
      required: true,
      options: [...collections, ...expenses],
    });
  if (type === "INTER_UNIT_TRANSFER")
    fields.push({
      name: "destination_account_id",
      label: "BOFT destination account",
      options: destinationAccounts,
      required: true,
    });
  fields.push(
    { name: "reference", label: "Referencia (opcional)" },
    {
      name: "reason",
      label: "Override reason / closed-month change",
      help: "Required if the period is closed or the reimbursement is outside the 14-day window.",
      wide: true,
    },
  );
  return (
    <>
      <div className="formgrid" style={{ marginBottom: 20 }}>
        <label>
          Tipo
          <select
            value={type}
            disabled={!!saleId}
            onChange={(e) => setType(e.target.value)}
          >
            {[
              ["EXPENSE", "Expense"],
              ["COLLECTION", "Collection"],
              ["OWNER_INJECTION", "Owner Injection"],
              ["OWNER_DRAW", "Owner Draw / Reimbursement"],
              ["INTER_UNIT_TRANSFER", "Transferencia interna a BOFT"],
              ["REFUND", "Refund"],
            ].map(([v, l]) => (
              <option value={v} key={v}>
                {l}
              </option>
            ))}
          </select>
        </label>
        {type === "EXPENSE" && (
          <label>
            Pagado por
            <select value={paidBy} onChange={(e) => setPaidBy(e.target.value)}>
              <option value="Business">ToolTag / Main Account</option>
              <option value="Owner">Owner — creates reimbursement due</option>
            </select>
          </label>
        )}
        {type === "OWNER_DRAW" && (
          <label>
            Subtipo
            <select
              value={subtype}
              onChange={(e) => setSubtype(e.target.value)}
            >
              <option>Personal Draw</option>
              <option>Reimbursement</option>
            </select>
          </label>
        )}
      </div>
      <Form
        key={`${type}:${subtype}:${paidBy}`}
        operation="movement"
        fields={fields}
        hidden={{
          request_id: requestId,
          type,
          subtype,
          paid_by: paidBy,
          ...(saleId ? { sale_id: saleId } : {}),
          ...(type === "INTER_UNIT_TRANSFER"
            ? { destination_unit_id: "10000000-0000-0000-0000-000000000001" }
            : {}),
        }}
        back={
          saleId ? `/app/finance/sales/${saleId}` : "/app/finance/transactions"
        }
        button="Record Transaction"
      />
    </>
  );
}
