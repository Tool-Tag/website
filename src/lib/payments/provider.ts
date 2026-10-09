export type PaymentMethod = "Card" | "Zelle" | "Venmo";
export type PaymentScope = "full" | "fee_only";
export type PaymentProviderState =
  | "pending"
  | "pending_verification"
  | "paid_confirmed";

export type StartPaymentInput = {
  attemptId: string;
  amountCents: number;
  currency: "usd";
  description: string;
  customerEmail: string;
  successUrl: string;
  cancelUrl: string;
  jobId: string;
  quoteId: string;
  paymentScope: PaymentScope;
};

export type StartPaymentResult = {
  state: PaymentProviderState;
  provider: "stripe" | "manual";
  providerReference?: string;
  redirectUrl?: string;
};

export interface PaymentProvider {
  readonly provider: "stripe" | "manual";
  readonly method: PaymentMethod;
  isConfigured(): boolean;
  start(input: StartPaymentInput): Promise<StartPaymentResult>;
}
