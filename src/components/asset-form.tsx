"use client";
import { useState } from "react";
import { Form, type Field } from "./form";
export function AssetForm({
  categories,
  expenses,
  expense,
  lockedExpense = false,
  defaultName,
  back = "/app/equipment",
}: {
  categories: { value: string; label: string }[];
  expenses: { value: string; label: string }[];
  expense?: string;
  lockedExpense?: boolean;
  defaultName?: string;
  back?: string;
}) {
  const [origin, setOrigin] = useState("Purchased");
  const fields: Field[] = [
    { name: "name", label: "Equipment Name", required: true, value: defaultName },
    {
      name: "category_id",
      label: "Equipment Category",
      options: categories,
      required: true,
    },
    { name: "serial_number", label: "Serial Number" },
    { name: "warranty_expiration", label: "Warranty Expiration", type: "date" },
    { name: "notes", label: "Notes", type: "textarea", wide: true },
  ];
  if (origin === "Purchased" && !lockedExpense)
    fields.unshift({
      name: "source_expense_id",
      label: "Unlinked Equipment Purchase",
      options: expenses,
      required: true,
      value: expense,
    });
  else if (origin !== "Purchased")
    fields.push(
      {
        name: "estimated_value",
        label: "Estimated Value (informational)",
        type: "number",
        required: true,
      },
      { name: "donated_by", label: "Donated By", required: true },
      {
        name: "received_date",
        label: "Received Date",
        type: "date",
        required: true,
      },
    );
  return (
    <>
      <label style={{ marginBottom: 18 }}>Source<select disabled={lockedExpense} value={origin} onChange={(e) => setOrigin(e.target.value)}>
          <option>Purchased</option>
          <option>Donated</option>
        </select>
      </label>
      <Form
        key={origin}
        operation="asset"
        hidden={{ origin, ...(lockedExpense && expense ? {source_expense_id:expense} : {}) }}
        fields={fields}
        back={back}
      />
    </>
  );
}
