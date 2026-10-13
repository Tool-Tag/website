import {PAYMENT_PAYEE_DISCLAIMER,VENMO_ACCOUNT_NAME,venmoPaymentUrl} from "@/lib/payments/venmo";
export function ManualPaymentPayee(){return <p className="notice">{PAYMENT_PAYEE_DISCLAIMER}</p>;}
export function VenmoPaymentLink({handle}:{handle:string}) {
 const url=venmoPaymentUrl(handle);
 return <><p>Account name: <strong>{VENMO_ACCOUNT_NAME}</strong></p>{url && <a className="button secondary" href={url} target="_blank" rel="noopener noreferrer">Open Venmo ↗</a>}<p className="muted">Complete your payment in Venmo, then submit it here for verification. Opening Venmo does not confirm payment.</p></>;
}
