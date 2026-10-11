import {
  createHmac,
  timingSafeEqual,
} from "node:crypto";
import type {
  PaymentProvider,
  StartPaymentInput,
  StartPaymentResult,
} from "./provider";

export const STRIPE_API_VERSION = "2025-06-30.basil";

type FetchLike = typeof fetch;

type StripeCheckoutSession = {
  id: string;
  url?: string | null;
  amount_total?: number | null;
  currency?: string | null;
  livemode?: boolean;
  payment_status?: string | null;
  client_reference_id?: string | null;
  metadata?: Record<string, string> | null;
};

export type StripeEvent = {
  id: string;
  livemode?: boolean;
  type: string;
  data: {
    object: StripeCheckoutSession;
  };
};

function stripeApiBase() {
  return (process.env.STRIPE_API_BASE || "https://api.stripe.com/v1").replace(
    /\/$/,
    "",
  );
}

export function stripeConfigured() {
 const secret=process.env.STRIPE_SECRET_KEY?.trim()??"";
 const publicKey=process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY?.trim()??"";
 return secret.startsWith("sk_test_") && Boolean(process.env.STRIPE_WEBHOOK_SECRET?.trim().startsWith("whsec_")) && (!publicKey || publicKey.startsWith("pk_test_"));
}
export function stripeTestEvent(event: StripeEvent) {
 return event.livemode===false;
}

export function stripeTestMode() {
  return process.env.STRIPE_SECRET_KEY?.startsWith("sk_test_") ?? false;
}

export class StripePaymentProvider implements PaymentProvider {
  readonly provider = "stripe" as const;
  readonly method = "Card" as const;

  constructor(private readonly fetcher: FetchLike = fetch) {}

  isConfigured() {
    return stripeConfigured();
  }

  async start(input: StartPaymentInput): Promise<StartPaymentResult> {
    const secret = process.env.STRIPE_SECRET_KEY?.trim();
    if (!stripeConfigured()) {
      throw new Error("Stripe TEST card payments are not configured correctly.");
    }

    const params = new URLSearchParams({
      mode: "payment",
      locale: "en",
      success_url: input.successUrl,
      cancel_url: input.cancelUrl,
      client_reference_id: input.attemptId,
      "payment_method_types[0]": "card",
      "line_items[0][price_data][currency]": input.currency,
      "line_items[0][price_data][unit_amount]": String(input.amountCents),
      "line_items[0][price_data][product_data][name]": input.description,
      "line_items[0][quantity]": "1",
      "metadata[attempt_id]": input.attemptId,
      "metadata[job_id]": input.jobId,
      "metadata[quote_id]": input.quoteId,
      "metadata[payment_scope]": input.paymentScope,
      "payment_intent_data[metadata][attempt_id]": input.attemptId,
    });

    if (input.customerEmail?.trim()) params.set("customer_email",input.customerEmail.trim());

    const response = await this.fetcher(
      `${stripeApiBase()}/checkout/sessions`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${secret}`,
          "Content-Type": "application/x-www-form-urlencoded",
          "Stripe-Version": STRIPE_API_VERSION,
          "Idempotency-Key": input.attemptId,
        },
        body: params,
      },
    );

    const body = (await response.json()) as StripeCheckoutSession & {
      error?: { message?: string; code?: string; param?: string };
    };

    if (!response.ok || !body.id?.startsWith("cs_test_") || !body.url || body.livemode === true) {
      console.error("STRIPE_CHECKOUT_REJECTED",{status:response.status,code:body.error?.code,param:body.error?.param,diagnostic:body.error?.param==="payment_method_types"?body.error?.message:undefined});
      throw new Error(
        body.error?.message || "Card checkout could not be started.",
      );
    }

    return {
      provider: "stripe",
      state: "pending",
      providerReference: body.id,
      redirectUrl: body.url,
    };
  }
}

export function verifyStripeSignature(
  rawBody: string,
  signatureHeader: string,
  endpointSecret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
  toleranceSeconds = 300,
) {
  const parts = signatureHeader.split(",");
  const timestamp = Number(
    parts.find((part) => part.startsWith("t="))?.slice(2),
  );
  const signatures = parts
    .filter((part) => part.startsWith("v1="))
    .map((part) => part.slice(3));

  if (
    !Number.isFinite(timestamp) ||
    !signatures.length ||
    Math.abs(nowSeconds - timestamp) > toleranceSeconds
  ) {
    return false;
  }

  const expected = createHmac("sha256", endpointSecret)
    .update(`${timestamp}.${rawBody}`)
    .digest("hex");

  return signatures.some((candidate) => {
    if (candidate.length !== expected.length) return false;
    try {
      return timingSafeEqual(
        Buffer.from(candidate, "hex"),
        Buffer.from(expected, "hex"),
      );
    } catch {
      return false;
    }
  });
}

export function parseVerifiedStripeEvent(
  rawBody: string,
  signatureHeader: string,
  endpointSecret: string,
): StripeEvent {
  if (!verifyStripeSignature(rawBody, signatureHeader, endpointSecret)) {
    throw new Error("Invalid Stripe webhook signature.");
  }
  return JSON.parse(rawBody) as StripeEvent;
}
