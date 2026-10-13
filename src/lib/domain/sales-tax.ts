import { cents, decimal } from "./money";
export const DEFAULT_SALES_TAX_RATE = "7.45";
export const TAX_PRICE_NOTICE = "Price subject to taxes — final total includes Utah sales tax.";
export type TaxBreakdown = {subtotal:string;tax_rate:string;tax_amount:string;total:string;tax_rates?:(number|string)[]};
export function salesTax(subtotal:string,rate=DEFAULT_SALES_TAX_RATE):TaxBreakdown {
 if(!/^\d{1,3}(\.\d{1,3})?$/.test(rate)||Number(rate)>100)throw new Error("Sales tax rate must be between 0 and 100 percent, with at most three decimal places.");
 const [whole,fraction=""]=rate.split(".");const milliPercent=BigInt(whole)*1000n+BigInt(fraction.padEnd(3,"0"));const base=cents(subtotal);const tax=(base*milliPercent+50000n)/100000n;
 return {subtotal:decimal(base),tax_rate:String(Number(rate)),tax_amount:decimal(tax),total:decimal(base+tax)};
}
