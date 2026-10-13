import {money} from "@/lib/domain/money";
import {salesTax,TAX_PRICE_NOTICE,type TaxBreakdown as Pricing} from "@/lib/domain/sales-tax";
export function TaxBreakdown({pricing,subtotal,rate="0"}:{pricing?:Partial<Pricing>|null;subtotal?:string;rate?:string}) {
 const p=pricing?.subtotal!==undefined && pricing?.tax_amount!==undefined && pricing?.total!==undefined ? pricing : salesTax(subtotal ?? "0.00",rate);
 return <div className="tax-breakdown"><p>Subtotal <strong>{money(p.subtotal)}</strong></p><p>Utah Sales Tax ({p.tax_rates && p.tax_rates.length>1 ? `mixed rates: ${p.tax_rates.map(r=>`${Number(r)}%`).join(", ")}` : `${Number(p.tax_rate ?? rate)}%`}) <strong>{money(p.tax_amount)}</strong></p><p>Total <strong>{money(p.total)}</strong></p><p className="muted">{TAX_PRICE_NOTICE}</p></div>;
}
