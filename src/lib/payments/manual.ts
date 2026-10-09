import type {
  PaymentMethod,
  PaymentProvider,
  StartPaymentInput,
  StartPaymentResult,
} from "./provider";

export class ManualPaymentProvider implements PaymentProvider {
  readonly provider = "manual" as const;

  constructor(
    readonly method: Extract<PaymentMethod, "Zelle" | "Venmo">,
    private readonly destination: string | null | undefined,
  ) {}

  isConfigured() {
    return Boolean(this.destination?.trim());
  }

  async start(_input: StartPaymentInput): Promise<StartPaymentResult> {
    if (!this.isConfigured()) {
      throw new Error(`${this.method} is not configured yet.`);
    }
    return {
      provider: "manual",
      state: "pending_verification",
    };
  }
}
