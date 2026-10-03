export interface DriveDocument {
  fileId: string;
  name: string;
}
export interface DocumentStore {
  ensureFolder(parentId: string, name: string): Promise<string>;
  upload(
    parentId: string,
    name: string,
    content: Uint8Array,
    mimeType: string,
  ): Promise<DriveDocument>;
}
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
    super(`${provider} is not connected. Nothing has been uploaded or sent.`);
  }
}
export const drive: DocumentStore = {
  async ensureFolder() {
    throw new IntegrationUnavailable("Google Drive");
  },
  async upload() {
    throw new IntegrationUnavailable("Google Drive");
  },
};
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
