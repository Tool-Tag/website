"use client";
import { useState } from "react";
import { Form, type Field } from "./form";
export function AssetForm({
  categories,
  expenses,
  expense,
}: {
  categories: { value: string; label: string }[];
  expenses: { value: string; label: string }[];
  expense?: string;
}) {
  const [origin, setOrigin] = useState("Purchased");
  const fields: Field[] = [
    { name: "name", label: "Equipment name", required: true },
    {
      name: "category_id",
      label: "Equipment category",
      options: categories,
      required: true,
    },
    { name: "serial_number", label: "Serial number" },
    { name: "warranty_expiration", label: "Warranty expiration", type: "date" },
    { name: "notes", label: "Notes", type: "textarea", wide: true },
  ];
  if (origin === "Purchased")
    fields.unshift({
      name: "source_expense_id",
      label: "Unlinked equipment purchase",
      options: expenses,
      required: true,
      value: expense,
    });
  else
    fields.push(
      {
        name: "estimated_value",
        label: "Estimated value (informational)",
        type: "number",
        required: true,
      },
      { name: "donated_by", label: "Donated by", required: true },
      {
        name: "received_date",
        label: "Received date",
        type: "date",
        required: true,
      },
    );
  return (
    <>
      <label style={{ marginBottom: 18 }}>
        Origin
        <select value={origin} onChange={(e) => setOrigin(e.target.value)}>
          <option>Purchased</option>
          <option>Donated</option>
        </select>
      </label>
      <Form
        key={origin}
        operation="asset"
        hidden={{ origin }}
        fields={fields}
        back="/app/equipment"
      />
    </>
  );
}
