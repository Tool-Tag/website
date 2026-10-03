import { money, quoteTotal } from "./money";
import type { QuoteItem } from "./quote-items";
export function itemDetails(i: QuoteItem): string[] {
  if (i.engraving_type === "Fee") return [i.notes || "Additional fee"];
  const lines = i.marks?.length
    ? [
        `${i.marks.length} engraving(s) per article`,
        ...i.marks.map(
          (m, n) =>
            `${n + 1}. ${m.type === "Text" ? "Text" : "Image / Logo"} · ${m.location || "Location not recorded"} · ${m.type === "Text" ? m.text : [m.description, m.url].filter(Boolean).join(" · ")}${m.paint_fill ? ` · Paint fill: ${m.paint_details?.mode === "single" ? m.paint_details.color : m.paint_details?.instructions || "Color not recorded"}` : m.paint_fill === false ? " · Paint fill: no" : ""}`,
        ),
      ]
    : [i.engraving_type, i.engraving_text || ""];
  if (i.width_mm || i.height_mm)
    lines.push(`Area: ${i.width_mm || "—"} × ${i.height_mm || "—"} mm`);
  if (i.paint_fill)
    lines.push(
      i.paint_details
        ? i.paint_details.mode === "single"
          ? `Paint fill: ${i.paint_details.color}`
          : `Paint fill: multiple colors · ${i.paint_details.instructions}`
        : `Paint fill: ${i.colors || "unspecified"} color(s)`,
    );
  else if (!i.marks?.some((m) => m.paint_fill)) lines.push("Paint fill: no");
  if (i.notes) lines.push(i.notes);
  return lines;
}
export function itemSubtotal(i: QuoteItem) {
  return money(
    quoteTotal([{ quantity: i.quantity, unit_price: String(i.unit_price) }]),
  );
}
