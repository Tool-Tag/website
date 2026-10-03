export function cents(value: string): bigint {
  if (!/^\d+(\.\d{1,2})?$/.test(value))
    throw new Error("Use a positive amount with at most two decimals");
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
}
export function decimal(value: bigint): string {
  const sign = value < 0n ? "-" : "";
  const n = value < 0n ? -value : value;
  return `${sign}${n / 100n}.${String(n % 100n).padStart(2, "0")}`;
}
export function quoteTotal(
  items: { quantity: number; unit_price: string }[],
): string {
  return decimal(
    items.reduce((n, i) => {
      if (!Number.isSafeInteger(i.quantity) || i.quantity <= 0)
        throw new Error("Invalid quantity");
      return n + cents(i.unit_price) * BigInt(i.quantity);
    }, 0n),
  );
}
export function money(value: unknown) {
  const s = String(value ?? "0");
  const [whole, fraction = ""] = s.split(".");
  return `$${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${fraction.padEnd(2, "0").slice(0, 2)}`;
}
