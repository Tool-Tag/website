"use client";
import { useState, useActionState, useRef } from "react";
import { mutate } from "@/app/actions";
import { quoteTotal, money } from "@/lib/domain/money";
import {
  blankItem,
  imageLinks,
  withAdaptation,
  type QuoteItem,
  type Mark,
} from "@/lib/domain/quote-items";
export function QuoteBuilder({
  customers,
  customer,
  revises,
  initial,
}: {
  customers: { id: string; name: string }[];
  customer?: string;
  revises?: string;
  initial?: QuoteItem[];
}) {
  const [items, setItems] = useState<QuoteItem[]>(
    (initial ?? []).filter((i) => !i.adaptation_fee),
  );
  const [draft, setDraft] = useState<QuoteItem>(blankItem);
  const [editing, setEditing] = useState<number | null>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const [state, action, pending] = useActionState(
    mutate.bind(null, "quote", "/app/quotes"),
    {},
  );
  function open(index: number | null) {
    setEditing(index);
    const item = index === null ? blankItem() : items[index];
    setDraft({
      ...item,
      marks: item.marks?.length
        ? item.marks
        : [
            {
              type:
                item.engraving_type === "Image / Logo"
                  ? "Image / Logo"
                  : "Text",
              text: item.engraving_text,
              url: "",
            },
          ],
    });
    dialog.current?.showModal();
  }
  function update(key: keyof QuoteItem, value: string | number | boolean) {
    setDraft((d) => ({ ...d, [key]: value }));
  }
  function mark(index: number, patch: Partial<Mark>) {
    setDraft((d) => ({
      ...d,
      marks: d.marks?.map((m, i) => (i === index ? { ...m, ...patch } : m)),
    }));
  }
  let total = "0.00";
  try {
    total = quoteTotal(withAdaptation(items));
  } catch {
    /* The item form validates prices before adding. */
  }
  const designs = imageLinks(items);
  return (
    <>
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
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <p className="muted">
          Precio manual por artículo. Adaptación para Falcon: $3 por imagen/logo
          diferente, una sola vez por cotización.
        </p>
        <div className="actions">
          <button
            type="button"
            className="secondary"
            onClick={() => open(null)}
          >
            Agregar artículo
          </button>
        </div>
        {items.map((item, i) => (
          <section className="item" key={i}>
            <h3>{item.article}</h3>
            <p>
              {item.quantity} × {money(item.unit_price)}
            </p>
            <p className="quote-mark-summary">
              {item.marks
                ?.map((m) => (m.type === "Text" ? m.text : m.url))
                .join(" · ") || item.engraving_text}
            </p>
            <div className="actions">
              <button
                type="button"
                className="secondary"
                onClick={() => open(i)}
              >
                Editar artículo
              </button>
              <button
                type="button"
                className="secondary"
                onClick={() => setItems((old) => old.filter((_, n) => n !== i))}
              >
                Quitar artículo
              </button>
            </div>
          </section>
        ))}

        {designs.length > 0 && (
          <p>
            Adaptación para Falcon: {designs.length} diseño(s) × $3 ={" "}
            {money(String(designs.length * 3))}
          </p>
        )}
        <h3>Total: {money(total)}</h3>
        <label style={{ margin: "20px 0" }}>
          Notas generales
          <textarea name="notes" />
        </label>
        {state.error && (
          <p role="alert" className="notice error">
            {state.error}
          </p>
        )}
        <button disabled={pending || !items.length}>
          {pending
            ? "Guardando…"
            : revises
              ? "Crear revisión"
              : "Guardar cotización"}
        </button>
      </form>
      <dialog
        ref={dialog}
        className="quote-dialog"
        aria-labelledby="article-title"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            const marks = (
              draft.engraving_type === "Fee" ? [] : (draft.marks ?? [])
            ).map((m) => ({ ...m, text: m.text.trim(), url: m.url.trim() }));
            const saved = {
              ...draft,
              marks,
              engraving_type:
                draft.engraving_type === "Fee"
                  ? "Fee"
                  : marks.some((m) => m.type === "Image / Logo")
                    ? "Image / Logo"
                    : "Text",
              engraving_text: marks
                .map((m) =>
                  m.type === "Text" ? m.text : `Imagen / Logo: ${m.url}`,
                )
                .join("\n"),
            };
            setItems((old) =>
              editing === null
                ? [...old, saved]
                : old.map((v, i) => (i === editing ? saved : v)),
            );
            dialog.current?.close();
          }}
        >
          <div className="actions">
            <h2 id="article-title">
              {editing === null ? "Agregar artículo" : "Editar artículo"}
            </h2>
            <button
              type="button"
              className="secondary"
              aria-label="Cerrar"
              onClick={() => dialog.current?.close()}
            >
              Cerrar
            </button>
          </div>
          <div className="formgrid">
            <label>
              Artículo / modelo
              <input
                autoFocus
                required
                value={draft.article}
                onChange={(e) => update("article", e.target.value)}
              />
            </label>
            <label>
              Cantidad
              <input
                type="number"
                min="1"
                step="1"
                required
                value={draft.quantity}
                onChange={(e) => update("quantity", Number(e.target.value))}
              />
            </label>
            <label>
              Precio unitario (USD)
              <input
                type="number"
                min="0"
                step="0.01"
                required
                value={draft.unit_price}
                onChange={(e) => update("unit_price", e.target.value)}
              />
            </label>
            <label>
              Concepto
              <select
                value={draft.engraving_type === "Fee" ? "Fee" : "Engraving"}
                onChange={(e) =>
                  update(
                    "engraving_type",
                    e.target.value === "Fee" ? "Fee" : "Text",
                  )
                }
              >
                <option value="Engraving">Grabado</option>
                <option value="Fee">Cargo adicional</option>
              </select>
            </label>
            {draft.engraving_type !== "Fee" && (
              <>
                <label>
                  Ancho (mm)
                  <input
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={draft.width_mm}
                    onChange={(e) => update("width_mm", e.target.value)}
                  />
                </label>
                <label>
                  Alto (mm)
                  <input
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={draft.height_mm}
                    onChange={(e) => update("height_mm", e.target.value)}
                  />
                </label>
                <label className="checkbox">
                  <input
                    type="checkbox"
                    checked={draft.paint_fill}
                    onChange={(e) => update("paint_fill", e.target.checked)}
                  />
                  Relleno de pintura
                </label>
                {draft.paint_fill && (
                  <label>
                    Colores
                    <input
                      type="number"
                      min="1"
                      step="1"
                      required
                      value={draft.colors}
                      onChange={(e) => update("colors", Number(e.target.value))}
                    />
                  </label>
                )}
              </>
            )}
          </div>
          {draft.engraving_type !== "Fee" && (
            <>
              {draft.marks?.map((m, i) => (
                <fieldset className="item" key={i}>
                  <legend>Marca / grabado {i + 1}</legend>
                  <label>
                    Tipo
                    <select
                      value={m.type}
                      onChange={(e) =>
                        mark(i, { type: e.target.value as Mark["type"] })
                      }
                    >
                      <option value="Text">Letras</option>
                      <option value="Image / Logo">Imagen / Logo</option>
                    </select>
                  </label>
                  {m.type === "Text" ? (
                    <label>
                      Texto a grabar · {Array.from(m.text).length} caracteres
                      <input
                        required
                        value={m.text}
                        onChange={(e) => mark(i, { text: e.target.value })}
                      />
                    </label>
                  ) : (
                    <>
                      <label>
                        Enlace de la imagen o logo
                        <input
                          type="url"
                          pattern="https?://.*"
                          required
                          placeholder="https://…"
                          value={m.url}
                          onChange={(e) => mark(i, { url: e.target.value })}
                        />
                      </label>
                      {designs.length > 0 && (
                        <label>
                          Reutilizar un diseño
                          <select
                            value=""
                            onChange={(e) => mark(i, { url: e.target.value })}
                          >
                            <option value="">
                              Seleccionar diseño existente…
                            </option>
                            {designs.map((url, n) => (
                              <option key={url} value={url}>
                                Diseño {n + 1}: {url}
                              </option>
                            ))}
                          </select>
                        </label>
                      )}
                      <small>
                        Usa el mismo enlace para repetir un diseño sin cobrar
                        otra adaptación.
                      </small>
                    </>
                  )}
                  {(draft.marks?.length ?? 0) > 1 && (
                    <button
                      type="button"
                      className="secondary"
                      onClick={() =>
                        setDraft((d) => ({
                          ...d,
                          marks: d.marks?.filter((_, n) => n !== i),
                        }))
                      }
                    >
                      Quitar grabado
                    </button>
                  )}
                </fieldset>
              ))}
              <button
                type="button"
                className="secondary"
                onClick={() =>
                  setDraft((d) => ({
                    ...d,
                    marks: [
                      ...(d.marks ?? []),
                      { type: "Text", text: "", url: "" },
                    ],
                  }))
                }
              >
                Agregar otra marca / grabado
              </button>
            </>
          )}
          <label style={{ margin: "16px 0" }}>
            Notas
            <textarea
              value={draft.notes}
              onChange={(e) => update("notes", e.target.value)}
            />
          </label>
          <div className="actions">
            <button
              type="button"
              className="secondary"
              onClick={() => dialog.current?.close()}
            >
              Cancelar
            </button>
            <button>Guardar artículo</button>
          </div>
        </form>
      </dialog>
    </>
  );
}
