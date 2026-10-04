import { renderNotification } from "./notification-mail";
import { money } from "@/lib/domain/money";
import { itemDetails } from "@/lib/domain/quote-summary";
import type { QuoteItem } from "@/lib/domain/quote-items";
export type ReceiptSnapshot = {
 code:string; customer_name:string;
 original_quote:{code:string;items:QuoteItem[];total:string};
 extensions:{code:string;scope:string;total:string}[];
 totals:{base_amount:string;extensions_amount:string;grand_total:string;collected:string;refunded:string;balance_due:string};
 payments:{id:string;date:string;amount:string;method:string;reference?:string}[];
 paid_in_full:boolean;paid_in_full_date?:string;
};
export function receiptText(s:ReceiptSnapshot) {
 return `Job: ${s.code}\nCustomer: ${s.customer_name}\n\nORIGINAL QUOTE ${s.original_quote.code}\n${s.original_quote.items.map(i=>`${i.article} × ${i.quantity}\n${itemDetails(i).join("\n")}`).join("\n")}\nSubtotal: ${money(s.totals.base_amount)}\n\n${s.extensions.map(x=>`${x.code}\n${x.scope}\nSubtotal: ${money(x.total)}`).join("\n\n")}\n\nGRAND TOTAL: ${money(s.totals.grand_total)}\n\nPAYMENT HISTORY\n${s.payments.map(p=>`${p.date} · ${money(p.amount)} · ${p.method || "—"} · ${p.reference || ""}`).join("\n")}\n\nAmount paid: ${money(s.totals.collected)}\nRefunds: ${money(s.totals.refunded)}\nBalance due: ${money(s.totals.balance_due)}\n${s.paid_in_full ? `PAID IN FULL\nPaid in full date: ${s.paid_in_full_date}` : "Payment status: balance pending or refund adjustment"}\n\nThis payment summary is separate from confirmation of physical delivery.`;
}
export function renderJobReceipt(s:ReceiptSnapshot,to:string) {
 return renderNotification(
  s.paid_in_full ? `Payment confirmed — ${s.code}` : `ToolTag Payment Summary — ${s.code}`,
  s.paid_in_full
    ? `ToolTag has confirmed your payment.\n\n${receiptText(s)}`
    : receiptText(s),
  to,
  "PAYMENT_RECEIPT",
 );
}
