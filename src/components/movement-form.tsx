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
      label: "Fecha del movimiento",
      type: "date",
      value: today,
      required: true,
    },
    {
      name: "account_id",
      label: "Cuenta atribuida",
      options: accounts,
      required: true,
      value: accounts[0]?.value,
    },
    { name: "description", label: "Descripción / propósito", required: true },
  ];
  if (type === "EXPENSE")
    fields.push(
      {
        name: "category_id",
        label: "Categoría",
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
        label: "¿Hospedaje?",
        value: "false",
        options: [
          { value: "false", label: "No" },
          { value: "true", label: "Sí: comprobante siempre requerido" },
        ],
      },
    );
  if (type === "COLLECTION" && !saleId)
    fields.push({
      name: "sale_id",
      label: "Venta (vacío = cobro sin vincular para revisión)",
      options: sales,
    });
  if (type === "COLLECTION")
    fields.push({
      name: "payment_method",
      label: "Método de pago",
      required: true,
      options: ["Cash", "Zelle", "Venmo"].map((value) => ({
        value,
        label: value,
      })),
    });
  if (type === "REFUND")
    fields.push({
      name: "original_id",
      label: "Cobro o gasto original",
      required: true,
      options: [...collections, ...expenses],
    });
  if (type === "INTER_UNIT_TRANSFER")
    fields.push({
      name: "destination_account_id",
      label: "Cuenta de destino BOFT",
      options: destinationAccounts,
      required: true,
    });
  fields.push(
    { name: "reference", label: "Referencia (opcional)" },
    {
      name: "reason",
      label: "Motivo de excepción / cambio en mes cerrado",
      help: "Obligatorio si el período está cerrado o el reembolso supera la ventana de 14 días.",
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
              ["EXPENSE", "Gasto"],
              ["COLLECTION", "Cobro"],
              ["OWNER_INJECTION", "Aportación del dueño"],
              ["OWNER_DRAW", "Retiro / reembolso al dueño"],
              ["INTER_UNIT_TRANSFER", "Transferencia interna a BOFT"],
              ["REFUND", "Devolución"],
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
              <option value="Owner">Dueño — genera saldo por reembolsar</option>
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
        button="Registrar movimiento"
      />
    </>
  );
}
