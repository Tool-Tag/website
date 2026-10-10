// Leave multipart overhead below Next.js and Vercel request limits.
export const PAYMENT_PROOF_MAX_BYTES = 3.5 * 1024 * 1024;
export const PAYMENT_PROOF_ERROR = "Use a PNG, JPG, or WebP screenshot up to 3.5 MB.";
export function paymentProofError(file: { size: number; type: string }): string | null {
  return file.size > PAYMENT_PROOF_MAX_BYTES || !["image/png", "image/jpeg", "image/webp"].includes(file.type)
    ? PAYMENT_PROOF_ERROR : null;
}
