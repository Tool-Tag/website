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
/** Normalize database and form decimals at their required scale. */
export function fixedDecimal(value: unknown, scale = 2): string {
  const source = typeof value === "number" && /e/i.test(String(value)) ? value.toFixed(scale) : String(value ?? "0");
  const match = /^([+-]?)(\d+)(?:\.(\d*))?$/.exec(source.trim() || "0");
  if (!match) throw new Error("Enter a valid decimal amount.");
  const [, sign, whole, fraction = ""] = match;
  const factor = 10n ** BigInt(scale);
  const digits = fraction.padEnd(scale, "0");
  const units = BigInt(whole) * factor + BigInt(digits.slice(0, scale) || "0")
    + (Number(digits[scale] ?? "0") >= 5 ? 1n : 0n);
  const prefix = sign === "-" && units !== 0n ? "-" : "";
  return prefix + (units / factor) + (scale ? "." + (units % factor).toString().padStart(scale, "0") : "");
}

export function money(value: unknown) {
  const fixed = fixedDecimal(value);
  const negative = fixed.startsWith("-");
  const [whole, fraction] = (negative ? fixed.slice(1) : fixed).split(".");
  return `${negative ? "-" : ""}$${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${fraction}`;
}
