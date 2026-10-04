import type { QuoteItem } from "@/lib/domain/quote-items";

export function WorkPreparation({ items }: { items: QuoteItem[] }) {
  const productionItems = items.filter((item) => item.engraving_type !== "Fee");

  return (
    <div className="work-prep-list">
      {productionItems.map((item, itemIndex) => (
        <section className="work-prep-item" key={itemIndex}>
          <div className="work-prep-head">
            <div>
              <small>Artículo</small>
              <h3>{item.article}</h3>
            </div>
            <span className="badge">Qty {item.quantity}</span>
          </div>

          {(item.marks ?? []).map((mark, markIndex) => (
            <div className="work-mark" key={markIndex}>
              <div className="work-mark-number">{markIndex + 1}</div>
              <div className="work-mark-content">
                <div className="work-mark-meta">
                  <strong>{mark.type === "Text" ? "Texto" : "Imagen / Logo"}</strong>
                  <span>{mark.location || "Ubicación no registrada"}</span>
                </div>

                {mark.type === "Text" ? (
                  <div className="work-text-preview">{mark.text}</div>
                ) : (
                  <div className="work-image-block">
                    {mark.url ? (
                      <img
                        className="work-image-preview"
                        src={mark.url}
                        alt={mark.description || `Logo para ${item.article}`}
                      />
                    ) : null}
                    {mark.description && <p>{mark.description}</p>}
                    {mark.url && (
                      <a href={mark.url} target="_blank" rel="noreferrer">
                        Abrir imagen original →
                      </a>
                    )}
                  </div>
                )}

                <dl className="work-instructions">
                  {(item.width_mm || item.height_mm) && (
                    <>
                      <dt>Área</dt>
                      <dd>
                        {item.width_mm || "—"} × {item.height_mm || "—"} mm
                      </dd>
                    </>
                  )}
                  <dt>Paint fill</dt>
                  <dd>
                    {mark.paint_fill
                      ? mark.paint_details?.mode === "single"
                        ? mark.paint_details.color || "Color no registrado"
                        : mark.paint_details?.instructions || "Múltiples colores"
                      : "No"}
                  </dd>
                  {mark.description && mark.type === "Text" && (
                    <>
                      <dt>Detalle</dt>
                      <dd>{mark.description}</dd>
                    </>
                  )}
                </dl>
              </div>
            </div>
          ))}

          {item.notes && (
            <div className="work-notes">
              <small>Notas</small>
              <p>{item.notes}</p>
            </div>
          )}
        </section>
      ))}

      {!productionItems.length && (
        <p className="muted">No hay artículos de producción en este Job.</p>
      )}
    </div>
  );
}
