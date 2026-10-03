export type Mark = {
  type: "Text" | "Image / Logo";
  text: string;
  url: string;
  location?: string;
  description?: string;
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
    ...(count ? [{ quantity: count, unit_price: "3.00" }] : []),
  ];
}
