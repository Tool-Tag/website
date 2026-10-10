export interface MessageProvider {
  send(message: {
    recipient: string;
    subject: string;
    body: string;
    idempotencyKey: string;
  }): Promise<{ providerId: string; sentAt: string }>;
}

export class IntegrationUnavailable extends Error {
  constructor(provider: string) {
    super(`${provider} is not connected. Nothing has been sent.`);
  }
}

export const email: MessageProvider = {
  async send() {
    throw new IntegrationUnavailable("Email");
  },
};

export function evidenceName(
  jobCode: string,
  type: "Receiving" | "Completed",
  sequence: number,
) {
  return `${jobCode}-${type}-${String(sequence).padStart(2, "0")}.jpg`;
}
