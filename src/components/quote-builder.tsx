"use client";
import { useState, useActionState } from "react";
import { mutate } from "@/app/actions";
import { quoteTotal, money } from "@/lib/domain/money";
type Item = {
  article: string;
  quantity: number;
  engraving_type: string;
  engraving_text: string;
  width_mm: string;
  height_mm: string;
  paint_fill: boolean;
  colors: number;
  unit_price: string;
  notes: string;
};
const blank = (): Item => ({
  article: "",
  quantity: 1,
  engraving_type: "Text",
  engraving_text: "",
  width_mm: "",
  height_mm: "",
  paint_fill: false,
  colors: 0,
  unit_price: "0.00",
  notes: "",
});
export function QuoteBuilder({
  customers,
  customer,
  revises,
  initial,
}: {
  customers: { id: string; name: string }[];
  customer?: string;
  revises?: string;
  initial?: Item[];
}) {
  const [items, setItems] = useState<Item[]>(
    initial?.length ? initial : [blank()],
  );
  const [state, action, pending] = useActionState(
    mutate.bind(null, "quote", "/app/quotes"),
    {},
  );
  const update = (
    i: number,
    key: keyof Item,
    value: string | boolean | number,
  ) =>
    setItems((old) =>
      old.map((v, n) => (n === i ? { ...v, [key]: value } : v)),
    );
  let total = "0.00";
  try {
    total = quoteTotal(items);
  } catch {
    /* validation shown on submit */
  }
  return (
    <form action={action}>
      <input type="hidden" name="items" value={JSON.stringify(items)} />
      {revises && <input type="hidden" name="revises_id" value={revises} />}
      <label>
        Cliente
        <select
          name="customer_id"
          required
          defaultValue={customer}
          disabled={!!revises}
        >
          <option value="">Seleccionar cliente…</option>
          {customers.map((c) => (
            <option value={c.id} key={c.id}>
              {c.name}
            </option>
          ))}
        </select>
      </label>
      <p className="muted">
        Precio manual por artículo. No se calcula precio automático.
      </p>
      {items.map((item, i) => (
        <section className="item" key={i}>
          <h3>Artículo {i + 1}</h3>
          <div className="formgrid">
            <label>
              Artículo / modelo
              <input
                required
                value={item.article}
                onChange={(e) => update(i, "article", e.target.value)}
              />
            </label>
            <label>
              Cantidad
              <input
                type="number"
                min="1"
                step="1"
                required
                value={item.quantity}
                onChange={(e) => update(i, "quantity", Number(e.target.value))}
              />
            </label>
            <label>
              Tipo
              <select
                value={item.engraving_type}
                onChange={(e) => update(i, "engraving_type", e.target.value)}
              >
                <option>Text</option>
                <option>Image / Logo</option>
                <option>Fee</option>
              </select>
            </label>
            <label>
              Precio unitario (USD)
              <input
                type="number"
                min="0"
                step="0.01"
                required
                value={item.unit_price}
                onChange={(e) => update(i, "unit_price", e.target.value)}
              />
            </label>
            {item.engraving_type === "Text" && (
              <label className="wide">
                Texto a grabar · {Array.from(item.engraving_text).length}{" "}
                caracteres
                <input
                  required
                  value={item.engraving_text}
                  onChange={(e) => update(i, "engraving_text", e.target.value)}
                />
              </label>
            )}
            {item.engraving_type !== "Fee" && (
              <>
                <label>
                  Ancho (mm)
                  <input
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={item.width_mm}
                    onChange={(e) => update(i, "width_mm", e.target.value)}
                  />
                </label>
                <label>
                  Alto (mm)
                  <input
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={item.height_mm}
                    onChange={(e) => update(i, "height_mm", e.target.value)}
                  />
                </label>
                <label className="checkbox">
                  <input
                    type="checkbox"
                    checked={item.paint_fill}
                    onChange={(e) => update(i, "paint_fill", e.target.checked)}
                  />
                  Relleno de pintura
                </label>
                {item.paint_fill && (
                  <label>
                    Colores
                    <input
                      type="number"
                      min="1"
                      value={item.colors}
                      onChange={(e) =>
                        update(i, "colors", Number(e.target.value))
                      }
                    />
                  </label>
                )}
              </>
            )}
            <label className="wide">
              Notas
              <input
                value={item.notes}
                onChange={(e) => update(i, "notes", e.target.value)}
              />
            </label>
          </div>
          {items.length > 1 && (
            <button
              type="button"
              className="secondary"
              style={{ marginTop: 12 }}
              onClick={() => setItems(items.filter((_, n) => n !== i))}
            >
              Quitar artículo
            </button>
          )}
        </section>
      ))}
      <div className="actions">
        <button
          type="button"
          className="secondary"
          onClick={() => setItems([...items, blank()])}
        >
          + Agregar artículo
        </button>
        <strong>Total: {money(total)}</strong>
      </div>
      <label style={{ margin: "20px 0" }}>
        Notas generales
        <textarea name="notes" />
      </label>
      {state.error && (
        <p role="alert" className="notice error">
          {state.error}
        </p>
      )}
      <button disabled={pending}>
        {pending
          ? "Guardando…"
          : revises
            ? "Crear revisión"
            : "Guardar cotización"}
      </button>
    </form>
  );
}
