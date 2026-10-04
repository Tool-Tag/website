"use client";
import { useState, useActionState, useRef } from "react";
import { QuoteScope } from "@/components/quote-scope";
import { mutate } from "@/app/actions";
import { quoteTotal, money } from "@/lib/domain/money";
import {
  blankItem,
  imageLinks,
  paintedQuantity,
  additionalEngravings,
  withAdaptation,
  type QuoteItem,
  type Mark,
} from "@/lib/domain/quote-items";
export function QuoteBuilder({
  customers,
  customer,
  revises,
  initial,
  notes,
  extensionId,
}: {
  customers: { id: string; name: string }[];
  customer?: string;
  revises?: string;
  initial?: QuoteItem[];
  notes?: string;
  extensionId?: string;
}) {
  const [items, setItems] = useState<QuoteItem[]>(
    (initial ?? []).filter((i) => !i.adaptation_fee && !i.paint_fee && !i.additional_engraving_fee).map((item) => ({ ...item, marks: item.marks?.map((m) => ({ ...m, paint_fill: m.paint_fill ?? item.paint_fill, paint_details: m.paint_details ?? (item.paint_fill ? item.paint_details : undefined) })) })),
  );
  const [draft, setDraft] = useState<QuoteItem>(blankItem);
  const [editing, setEditing] = useState<number | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [paintIndex, setPaintIndex] = useState(0);
  const paintDialog = useRef<HTMLDialogElement>(null);
  const [paint, setPaint] = useState({
    mode: "single" as "single" | "multiple",
    color: "",
    instructions: "",
  });
  const dialog = useRef<HTMLDialogElement>(null);
  const [state, action, pending] = useActionState(
    mutate.bind(null, extensionId ? "extension-scope" : "quote", extensionId ? `/app/job-extensions/${extensionId}` : "/app/quotes"),
    {},
  );
  function open(index: number | null) {
    setEditing(index);
    setConfirming(false);
    const item = index === null ? blankItem() : items[index];
    setDraft({
      ...item,
      marks: item.marks?.length
        ? item.marks.map((m) => ({ ...m, paint_fill: m.paint_fill ?? item.paint_fill, paint_details: m.paint_details ?? (item.paint_fill ? item.paint_details : undefined) }))
        : [
            {
              type:
                item.engraving_type === "Image / Logo"
                  ? "Image / Logo"
                  : "Text",
              text: item.engraving_text,
              url: "",
              location: "",
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
        {extensionId && <input type="hidden" name="id" value={extensionId}/>}
        <input type="hidden" name="items" value={JSON.stringify(items)} />
        {revises && <input type="hidden" name="revises_id" value={revises} />}
        <label>
          Cliente
          <select
            name="customer_id"
            required
            defaultValue={customer}
            disabled={!!revises || !!extensionId}
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
          diferente, una sola vez por cotización. Primer grabado incluido; cada adicional cuesta $5 por pieza. Pintura: $2 extra por pieza coloreada.
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
            <QuoteScope items={[item]} />
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
        {paintedQuantity(items) > 0 && <p>Relleno de pintura: {paintedQuantity(items)} pieza(s) × $2 = {money(String(paintedQuantity(items) * 2))}. Una vez por pieza, aunque tenga varios grabados con color.</p>}
        {additionalEngravings(items)>0 && <p>Grabados adicionales: {additionalEngravings(items)} × $5 = {money(String(additionalEngravings(items)*5))}</p>}
        <h3>Total: {money(total)}</h3>
        <label style={{ margin: "20px 0" }}>
          Notas generales
          <textarea name="notes" defaultValue={notes} />
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
              : extensionId ? "Guardar propuesta de extensión" : "Guardar cotización"}
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
              paint_fill: false,
              paint_details: undefined,
              colors: 0,
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
            if (!confirming) {
              setDraft(saved);
              setConfirming(true);
              return;
            }
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
          {confirming ? (
            <>
              <h3>Confirma el trabajo antes de guardar</h3>
              <QuoteScope items={[draft]} />
              {additionalEngravings([draft])>0 && <p>Grabados adicionales: {money(String(additionalEngravings([draft])*5))}</p>}
              {paintedQuantity([draft]) > 0 && <p>Pintura: {draft.quantity} pieza(s) × $2 = {money(String(draft.quantity * 2))} adicionales.</p>}
              <div className="actions">
                <button
                  type="button"
                  className="secondary"
                  onClick={() => setConfirming(false)}
                >
                  Volver a editar
                </button>
                <button>Confirmar y guardar</button>
              </div>
            </>
          ) : (
            <>
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
                  </>
                )}
              </div>
              {draft.engraving_type !== "Fee" && (
                <>
                  <p>
                    {draft.marks?.length ?? 0} grabado(s) por artículo. Agrega
                    uno por cada ubicación.
                  </p>
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
                      <label>
                        Ubicación del grabado
                        <input
                          required
                          value={m.location ?? ""}
                          onChange={(e) =>
                            mark(i, { location: e.target.value })
                          }
                          placeholder="Lado izquierdo, derecho, arriba…"
                        />
                      </label>
                      {m.type === "Text" ? (
                        <label>
                          Texto a grabar · {Array.from(m.text).length}{" "}
                          caracteres
                          <input
                            required
                            value={m.text}
                            onChange={(e) => mark(i, { text: e.target.value })}
                          />
                        </label>
                      ) : (
                        <>
                          <label>
                            Descripción del logo
                            <input
                              value={m.description ?? ""}
                              onChange={(e) =>
                                mark(i, { description: e.target.value })
                              }
                            />
                          </label>
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
                                onChange={(e) =>
                                  mark(i, { url: e.target.value })
                                }
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
                            Usa el mismo enlace para repetir un diseño sin
                            cobrar otra adaptación.
                          </small>
                        </>
                      )}
                      <label className="checkbox">
                        <input type="checkbox" checked={!!m.paint_fill} onChange={(e) => {
                          if (e.target.checked) {
                            setPaintIndex(i);
                            setPaint(m.paint_details ?? { mode: "single", color: "", instructions: "" });
                            paintDialog.current?.showModal();
                          } else mark(i, { paint_fill: false, paint_details: undefined });
                        }} />
                        Relleno de pintura · $2 extra por pieza
                      </label>
                      {m.paint_fill && <button type="button" className="secondary" onClick={() => {
                        setPaintIndex(i);
                        setPaint(m.paint_details ?? { mode: "single", color: "", instructions: "" });
                        paintDialog.current?.showModal();
                      }}>Editar pintura de este grabado</button>}
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
            </>
          )}
        </form>
      </dialog>
      <dialog
        ref={paintDialog}
        className="quote-dialog"
        aria-labelledby="paint-title"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            mark(paintIndex, { paint_fill: true, paint_details: paint });
            paintDialog.current?.close();
          }}
        >
          <h2 id="paint-title">Relleno de pintura</h2>
          <label>
            Coloreado
            <select
              value={paint.mode}
              onChange={(e) =>
                setPaint((p) => ({
                  ...p,
                  mode: e.target.value as "single" | "multiple",
                }))
              }
            >
              <option value="single">Un color</option>
              <option value="multiple">Varios colores</option>
            </select>
          </label>
          {paint.mode === "single" ? (
            <label>
              ¿Qué color?
              <input
                required
                value={paint.color}
                onChange={(e) =>
                  setPaint((p) => ({ ...p, color: e.target.value }))
                }
              />
            </label>
          ) : (
            <label>
              Instrucciones del coloreado
              <textarea
                required
                value={paint.instructions}
                onChange={(e) =>
                  setPaint((p) => ({ ...p, instructions: e.target.value }))
                }
              />
            </label>
          )}
          <div className="actions">
            <button
              type="button"
              className="secondary"
              onClick={() => paintDialog.current?.close()}
            >
              Cancelar
            </button>
            <button>Guardar pintura</button>
          </div>
        </form>
      </dialog>
    </>
  );
}
