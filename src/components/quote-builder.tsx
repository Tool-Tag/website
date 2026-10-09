"use client";
import { useState, useActionState, useRef } from "react";
import { QuoteImageInput } from "@/components/quote-image-input";
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
  getTaggedQuoteId,
}: {
  customers: { id: string; name: string }[];
  customer?: string;
  revises?: string;
  initial?: QuoteItem[];
  notes?: string;
  extensionId?: string;
  getTaggedQuoteId?: string;
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
  const operation = extensionId
    ? "extension-scope"
    : getTaggedQuoteId
      ? "get-tagged-review"
      : "quote";
  const back = extensionId
    ? `/app/job-extensions/${extensionId}`
    : getTaggedQuoteId
      ? `/app/quotes/${getTaggedQuoteId}`
      : "/app/quotes";
  const [state, action, pending] = useActionState(
    mutate.bind(null, operation, back),
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
        {getTaggedQuoteId && <input type="hidden" name="id" value={getTaggedQuoteId}/>}
        <input type="hidden" name="items" value={JSON.stringify(items)} />
        {revises && <input type="hidden" name="revises_id" value={revises} />}
        <label>
          Customer
          <select
            name="customer_id"
            required
            defaultValue={customer}
            disabled={!!revises || !!extensionId || !!getTaggedQuoteId}
          >
            <option value="">Select Customer…</option>
            {customers.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <p className="muted">
          Manual price per item. Falcon Adaptation: $3 per unique image/logo, charged once per Quote. The first engraving is included; each additional engraving costs $5 per piece. Paint Fill: $2 extra per painted piece.
        </p>
        <div className="actions">
          <button
            type="button"
            className="secondary"
            onClick={() => open(null)}
          >
            Add Item
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
                Edit Item
              </button>
              <button
                type="button"
                className="secondary"
                onClick={() => setItems((old) => old.filter((_, n) => n !== i))}
              >
                Remove Item
              </button>
            </div>
          </section>
        ))}

        {designs.length > 0 && (
          <p>
            Falcon Adaptation: {designs.length} design(s) × $3 ={" "}
            {money(String(designs.length * 3))}
          </p>
        )}
        {paintedQuantity(items) > 0 && <p>Paint Fill: {paintedQuantity(items)} piece(s) × $2 = {money(String(paintedQuantity(items) * 2))}. Charged once per piece, even with multiple colored engravings.</p>}
        {additionalEngravings(items)>0 && <p>Additional Engravings: {additionalEngravings(items)} × $5 = {money(String(additionalEngravings(items)*5))}</p>}
        <h3>Total: {money(total)}</h3>
        <label style={{ margin: "20px 0" }}>
          General Notes
          <textarea name="notes" defaultValue={notes} />
        </label>
        {state.error && (
          <p role="alert" className="notice error">
            {state.error}
          </p>
        )}
        <button disabled={pending || !items.length}>
          {pending
            ? "Saving…"
            : getTaggedQuoteId
              ? "Complete Request Review"
              : revises
                ? "Create Revision"
                : extensionId
                  ? "Save Extension Proposal"
                  : "Save Quote"}
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
                  m.type === "Text" ? m.text : `Image / Logo: ${m.url}`,
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
              {editing === null ? "Add Item" : "Edit Item"}
            </h2>
            <button
              type="button"
              className="secondary"
              aria-label="Close"
              onClick={() => dialog.current?.close()}
            >
              Close
            </button>
          </div>
          {confirming ? (
            <>
              <h3>Confirm the Work Before Saving</h3>
              <QuoteScope items={[draft]} />
              {additionalEngravings([draft])>0 && <p>Additional Engravings: {money(String(additionalEngravings([draft])*5))}</p>}
              {paintedQuantity([draft]) > 0 && <p>Paint: {draft.quantity} piece(s) × $2 = {money(String(draft.quantity * 2))} additional.</p>}
              <div className="actions">
                <button
                  type="button"
                  className="secondary"
                  onClick={() => setConfirming(false)}
                >
                  Back to Edit
                </button>
                <button>Confirm & Save</button>
              </div>
            </>
          ) : (
            <>
              <div className="formgrid">
                <label>
                  Item / Model
                  <input
                    autoFocus
                    required
                    value={draft.article}
                    onChange={(e) => update("article", e.target.value)}
                  />
                </label>
                <label>
                  Quantity
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
                  Unit Price (USD)
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
                  Type
                  <select
                    value={draft.engraving_type === "Fee" ? "Fee" : "Engraving"}
                    onChange={(e) =>
                      update(
                        "engraving_type",
                        e.target.value === "Fee" ? "Fee" : "Text",
                      )
                    }
                  >
                    <option value="Engraving">Engraving</option>
                    <option value="Fee">Additional Fee</option>
                  </select>
                </label>
                {draft.engraving_type !== "Fee" && (
                  <>
                    <label>
                      Width (mm)
                      <input
                        type="number"
                        min="0.01"
                        step="0.01"
                        value={draft.width_mm}
                        onChange={(e) => update("width_mm", e.target.value)}
                      />
                    </label>
                    <label>
                      Height (mm)
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
                    {draft.marks?.length ?? 0} engraving(s) per item. Add one for each location.
                  </p>
                  {draft.marks?.map((m, i) => (
                    <fieldset className="item" key={i}>
                      <legend>Mark / Engraving {i + 1}</legend>
                      <label>
                        Type
                        <select
                          value={m.type}
                          onChange={(e) =>
                            mark(i, { type: e.target.value as Mark["type"] })
                          }
                        >
                          <option value="Text">Text</option>
                          <option value="Image / Logo">Image / Logo</option>
                        </select>
                      </label>
                      <label>
                        Engraving Location
                        <input
                          required
                          value={m.location ?? ""}
                          onChange={(e) =>
                            mark(i, { location: e.target.value })
                          }
                          placeholder="Left side, right side, top…"
                        />
                      </label>
                      {m.type === "Text" ? (
                        <label>
                          Text to Engrave · {Array.from(m.text).length}{" "}
                          characters
                          <input
                            required
                            value={m.text}
                            onChange={(e) => mark(i, { text: e.target.value })}
                          />
                        </label>
                      ) : (
                        <>
                          <label>
                            Logo Description
                            <input
                              value={m.description ?? ""}
                              onChange={(e) =>
                                mark(i, { description: e.target.value })
                              }
                            />
                          </label>
                          <QuoteImageInput value={m.url} onChange={(url) => mark(i, { url })} />
                          {designs.length > 0 && (
                            <label>
                              Reuse a Design
                              <select
                                value=""
                                onChange={(e) =>
                                  mark(i, { url: e.target.value })
                                }
                              >
                                <option value="">
                                  Select Existing Design…
                                </option>
                                {designs.map((url, n) => (
                                  <option key={url} value={url}>
                                    Design {n + 1}: {url}
                                  </option>
                                ))}
                              </select>
                            </label>
                          )}
                          <small>
                            Use the same link to repeat a design without another adaptation charge.
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
                        Paint Fill · $2 extra per piece
                      </label>
                      {m.paint_fill && <button type="button" className="secondary" onClick={() => {
                        setPaintIndex(i);
                        setPaint(m.paint_details ?? { mode: "single", color: "", instructions: "" });
                        paintDialog.current?.showModal();
                      }}>Edit Paint for This Engraving</button>}
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
                          Remove Engraving
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
                    Add Another Mark / Engraving
                  </button>
                </>
              )}
              <label style={{ margin: "16px 0" }}>
                Notes
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
                  Cancel
                </button>
                <button>Save Item</button>
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
          <h2 id="paint-title">Paint Fill</h2>
          <label>
            Coloring
            <select
              value={paint.mode}
              onChange={(e) =>
                setPaint((p) => ({
                  ...p,
                  mode: e.target.value as "single" | "multiple",
                }))
              }
            >
              <option value="single">One Color</option>
              <option value="multiple">Multiple Colors</option>
            </select>
          </label>
          {paint.mode === "single" ? (
            <label>
              What Color?
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
              Coloring Instructions
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
              Cancel
            </button>
            <button>Save Paint</button>
          </div>
        </form>
      </dialog>
    </>
  );
}
