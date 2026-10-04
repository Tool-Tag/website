export type Mark = {
  type: "Text" | "Image / Logo";
  text: string;
  url: string;
  location?: string;
  description?: string;
  paint_fill?: boolean;
  paint_details?: QuoteItem["paint_details"];
};
export type QuoteItem = {
  article: string;
  quantity: number;
  engraving_type: string;
  engraving_text: string;
  width_mm: string;
  height_mm: string;
  paint_fill: boolean;
  colors: number;
  paint_details?: {
    mode: "single" | "multiple";
    color: string;
    instructions: string;
  };
  unit_price: string;
  notes: string;
  marks?: Mark[];
  adaptation_fee?: boolean;
  paint_fee?: boolean;
  additional_engraving_fee?: boolean;
  pricing?: { version?: number; engraving_count?: number; additional_engraving_charge?: number; paint_charge?: number; line_total?: number };
};
export const blankItem = (): QuoteItem => ({
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
  marks: [{ type: "Text", text: "", url: "" }],
});
export function imageLinks(items: QuoteItem[]) {
  return [
    ...new Set(
      items
        .flatMap((i) =>
          (i.engraving_type === "Fee" ? [] : (i.marks ?? []))
            .filter((m) => m.type === "Image / Logo")
            .map((m) => m.url.trim()),
        )
        .filter(Boolean),
    ),
  ];
}
export function withAdaptation(items: QuoteItem[]) {
  const count = imageLinks(items).length;
  return [
    ...items,
    ...(additionalEngravings(items) ? [{ quantity: additionalEngravings(items), unit_price: "5.00" }] : []),
    ...(paintedQuantity(items) ? [{ quantity: paintedQuantity(items), unit_price: "2.00" }] : []),
    ...(count ? [{ quantity: count, unit_price: "3.00" }] : []),
  ];
}

export function paintedQuantity(items: QuoteItem[]) {
  return items.reduce((count, item) => count + (item.engraving_type !== "Fee" && item.marks?.some((mark) => mark.paint_fill) ? item.quantity : 0), 0);
}

export function additionalEngravings(items: QuoteItem[]) {
  return items.reduce((sum, i) => sum + (i.engraving_type === "Fee" ? 0 : Math.max((i.marks?.length || 0)-1,0)*i.quantity),0);
}
