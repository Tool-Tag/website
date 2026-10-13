export const VENMO_ACCOUNT_NAME = "Bandits of the Framing";
export const PAYMENT_PAYEE_DISCLAIMER = "Payment will be received by Bandits of the Framing LLC, the legal owner of ToolTag (a registered DBA). Please include your job or quote number (e.g. TT-J-2026-00001) in the payment memo.";
export function venmoPaymentUrl(handle:string):string|null {
 const username=handle.trim().replace(/^@/,"");
 return /^[A-Za-z0-9_-]{1,64}$/.test(username) ? `https://venmo.com/${username}` : null;
}
