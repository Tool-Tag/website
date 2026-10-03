import type { QuoteItem } from "@/lib/domain/quote-items";
import { itemDetails, itemSubtotal } from "@/lib/domain/quote-summary";
import { money } from "@/lib/domain/money";
export function QuoteScope({ items }: { items: QuoteItem[] }) {
  return (
    <div className="quote-scope">
      {items.map((i, n) => (
        <section className="item" key={n}>
          <h3>{i.article}</h3>
          <p>
            {i.quantity} × {money(i.unit_price)} · {itemSubtotal(i)}
          </p>
          {itemDetails(i).map((line, k) => (
            <p className="quote-mark-summary" key={k}>
              {line}
            </p>
          ))}
        </section>
      ))}
    </div>
  );
}
