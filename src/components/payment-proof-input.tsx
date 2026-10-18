"use client";
import {usePhotoSelection} from "./use-photo-selection";
import {PHOTO_ACCEPT} from "@/lib/photos/normalize";
import { paymentProofError } from "@/lib/payments/proof";

export function PaymentProofInput({required = false}: {required?: boolean}) {
  const {preparing,error,onChange}=usePhotoSelection(paymentProofError);
  return <>
    <input type="file" name="proof" accept={PHOTO_ACCEPT} required={required} onChange={onChange}/>
    {preparing&&<small role="status">Preparing your photo…</small>}
    <small>PNG, JPG or WebP · Maximum 3.5 MB</small>
    {error && <span role="alert" className="notice error">{error}</span>}
  </>;
}
