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
    { name: "name", label: "Nombre del equipo", required: true },
    {
      name: "category_id",
      label: "Categoría de equipo",
      options: categories,
      required: true,
    },
    { name: "serial_number", label: "Número de serie" },
    { name: "warranty_expiration", label: "Fin de garantía", type: "date" },
    { name: "notes", label: "Notas", type: "textarea", wide: true },
  ];
  if (origin === "Purchased")
    fields.unshift({
      name: "source_expense_id",
      label: "Compra de equipo sin vincular",
      options: expenses,
      required: true,
      value: expense,
    });
  else
    fields.push(
      {
        name: "estimated_value",
        label: "Valor estimado (informativo)",
        type: "number",
        required: true,
      },
      { name: "donated_by", label: "Donado por", required: true },
      {
        name: "received_date",
        label: "Fecha de recepción",
        type: "date",
        required: true,
      },
    );
  return (
    <>
      <label style={{ marginBottom: 18 }}>
        Origen
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
