import { ManualPaymentProvider } from "./manual";
import type { PaymentMethod, PaymentProvider } from "./provider";
import { StripePaymentProvider, stripeConfigured } from "./stripe";

export function paymentProvider(
  method: PaymentMethod,
  destination?: string | null,
): PaymentProvider {
  if (method === "Card") return new StripePaymentProvider();
  return new ManualPaymentProvider(method, destination);
}

export function cardPaymentsConfigured() {
  return stripeConfigured();
}

export function toolTagPublicUrl() {
  const configured = process.env.TOOLTAG_PUBLIC_URL?.trim();
  if (configured) return configured.replace(/\/$/, "");

  const vercel = process.env.VERCEL_URL?.trim();
  if (vercel) return `https://${vercel.replace(/\/$/, "")}`;

  return "http://localhost:3000";
}
