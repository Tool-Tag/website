import {cents,decimal} from "./money";
import {TOOLTAG_TIMEZONE} from "./time";

export const DEFAULT_TAX_QUARTERS = ["01-01","04-01","07-01","10-01"];
export function validateTaxQuarters(starts: string[]) {
  if (starts.length !== 4 || new Set(starts).size !== 4) throw new Error("Enter four different quarter start dates.");
  let wraps = 0;
  starts.forEach((value, i) => {
    if (!/^\d{2}-\d{2}$/.test(value)) throw new Error("Use valid month/day start dates.");
    const [month, day] = value.split("-").map(Number);
    const date = new Date(Date.UTC(2001, month - 1, day));
    if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) throw new Error("Use valid annual dates; February 29 is unavailable.");
    if (value > starts[(i + 1) % 4]) wraps++;
  });
  if (wraps !== 1) throw new Error("Quarter start dates must follow Q1 → Q2 → Q3 → Q4 order.");
  return starts;
}
export function salesTaxQuarter(now = new Date(), starts: string[] = DEFAULT_TAX_QUARTERS) {
  validateTaxQuarters(starts);
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: TOOLTAG_TIMEZONE, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  const part = (type:string) => parts.find(p => p.type === type)!.value;
  const year = Number(part("year"));
  const today = `${year}-${part("month")}-${part("day")}`;
  const boundaries = [year - 1, year, year + 1].flatMap(y => starts.map((date, index) => ({date:`${y}-${date}`,index,year:y}))).sort((a,b)=>a.date.localeCompare(b.date));
  const currentIndex = boundaries.findLastIndex(b => b.date <= today);
  const current = boundaries[currentIndex];
  return {start:current.date, end:boundaries[currentIndex+1].date, label:`Q${current.index+1} ${current.year}`};
}

/** Uses the existing ledger's pinned, tax-exclusive revenue; never today's tax rate. */
export function salesTaxSummary(records: {type:string; amount:string; revenue:string; date:string}[], now = new Date(), starts: string[] = DEFAULT_TAX_QUARTERS) {
  const quarter = salesTaxQuarter(now, starts);
  let accumulated = 0n, current = 0n;
  for (const row of records) {
    const refund = row.type === "REFUND" && row.revenue.startsWith("-");
    if (row.type !== "SALE" && !refund) continue;
    const tax = cents(row.amount) - cents(refund ? row.revenue.slice(1) : row.revenue);
    const signedTax = refund ? -tax : tax;
    accumulated += signedTax;
    if (row.date >= quarter.start && row.date < quarter.end) current += signedTax;
  }
  return {accumulated: decimal(accumulated), current: decimal(current), quarter};
}
