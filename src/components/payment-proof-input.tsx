"use client";
import { useState } from "react";
import { paymentProofError } from "@/lib/payments/proof";

export function PaymentProofInput({required = false}: {required?: boolean}) {
  const [error, setError] = useState<string | null>(null);
  return <>
    <input type="file" name="proof" accept="image/png,image/jpeg,image/webp" required={required}
      onChange={(event) => {
        const file = event.currentTarget.files?.[0];
        const message = file ? paymentProofError(file) : null;
        event.currentTarget.setCustomValidity(message ?? "");
        setError(message);
      }} />
    <small>PNG, JPG or WebP · Maximum 3.5 MB</small>
    {error && <span role="alert" className="notice error">{error}</span>}
  </>;
}
