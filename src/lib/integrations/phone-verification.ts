import { createHash } from "node:crypto";
import { cookies } from "next/headers";
import { smsAdminClient } from "./sms-dispatch";
import { normalizeSmsPhone } from "./sms";
export const PHONE_VERIFICATION_COOKIE = "tooltag_phone_verification";
export function phoneVerificationEnabled(env: Record<string, string | undefined> = process.env) { return env.PHONE_VERIFICATION_ENABLED === "true"; }
export function verificationHash(value: string) { return createHash("sha256").update(value).digest("hex"); }
export function verificationSession(raw: string | undefined) {
 const parts=(raw??"").split(".");
 return /^[a-f0-9-]{36}$/.test(parts[0]??"") && /^[a-f0-9]{64}$/.test(parts[1]??"") && parts.length===2 ? {id:parts[0],secret:parts[1]} : null;
}
export async function verifiedPhone(phone: string, raw?: string) {
 if (!phoneVerificationEnabled()) return true;
 const session=verificationSession(raw??(await cookies()).get(PHONE_VERIFICATION_COOKIE)?.value);
 const normalized=normalizeSmsPhone(phone),db=smsAdminClient();
 if (!session || !normalized || !db) return false;
 const {data,error}=await db.rpc("phone_verification_valid",{p_id:session.id,p_session:verificationHash(session.secret),p_phone:normalized});
 return !error && data===true;
}
