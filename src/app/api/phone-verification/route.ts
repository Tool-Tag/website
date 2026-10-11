import { randomBytes, randomInt, randomUUID } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { smsAdminClient } from "@/lib/integrations/sms-dispatch";
import { normalizeSmsPhone, resolveSmsConfig, SnsSmsTransport } from "@/lib/integrations/sms";
import { PHONE_VERIFICATION_COOKIE, phoneVerificationEnabled, verificationHash, verificationSession } from "@/lib/integrations/phone-verification";
export const dynamic="force-dynamic";
function response(body: Record<string,unknown>,status=200) {return NextResponse.json(body,{status,headers:{"Cache-Control":"private, no-store"}});}
export async function GET() {return response({enabled:phoneVerificationEnabled()});}
export async function POST(request:NextRequest) {
 if (!phoneVerificationEnabled()) return response({error:"Phone verification is disabled."},404);
 if (request.headers.get("origin")!==request.nextUrl.origin) return response({error:"Unable to verify this request."},403);
 let id:string|undefined;
 const db=smsAdminClient();if(!db)return response({error:"Phone verification is not configured. Please contact ToolTag."},503);
 try {
  const raw=await request.text();if(raw.length>2000)return response({error:"Request too large."},413);
  const body=JSON.parse(raw);
  if(body.action==="verify") {
   const session=verificationSession(request.cookies.get(PHONE_VERIFICATION_COOKIE)?.value);
   if(!session || !/^\d{6}$/.test(String(body.code??"")))return response({error:"Enter the six-digit code sent to your phone."},400);
   const result=await db.rpc("check_phone_verification",{p_id:session.id,p_session:verificationHash(session.secret),p_code:verificationHash(session.id+":"+session.secret+":"+body.code)});
   return result.error || result.data!==true ? response({error:"The code is incorrect, expired or has too many attempts. Request a new code."},400) : response({verified:true});
  }
  if(body.action!=="send" || body.consent!==true)return response({error:"Agree to receive a one-time verification SMS first."},400);
  const phone=normalizeSmsPhone(String(body.phone??""));if(!phone)return response({error:"Enter a valid mobile phone number."},400);
  const current=await db.rpc("sms_runtime_config");const config=!current.error?resolveSmsConfig(current.data??{}):null;
  if(!config)return response({error:"Phone verification is not configured. Please contact ToolTag."},503);
  id=randomUUID();const secret=randomBytes(32).toString("hex"),code=String(randomInt(0,1000000)).padStart(6,"0");
  const network=verificationHash((process.env.GET_TAGGED_RATE_SALT??"tooltag-phone-verification")+":"+(request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()??"unknown"));
  const begin=await db.rpc("begin_phone_verification",{p_id:id,p_phone:phone,p_session:verificationHash(secret),p_code:verificationHash(id+":"+secret+":"+code),p_network:network});
  if(begin.error)return response({error:begin.error.message.includes("60 seconds")?"Wait 60 seconds before requesting another code.":"Too many verification requests. Try again later."},429);
  await new SnsSmsTransport(config).send(phone,`ToolTag verification code: ${code}. Expires in 10 minutes. Do not share this code. Reply STOP to opt out.`,process.env.TOOLTAG_SMS_MODE==="test",true);
  const saved=await db.rpc("phone_verification_result",{p_id:id,p_delivery:"Sent"});if(saved.error)throw new Error("Verification unavailable");
  const res=response({sent:true});res.cookies.set(PHONE_VERIFICATION_COOKIE,`${id}.${secret}`,{httpOnly:true,sameSite:"strict",secure:process.env.NODE_ENV==="production",path:"/",maxAge:600});return res;
 } catch {
  if(id)await db.rpc("phone_verification_result",{p_id:id,p_delivery:"Failed"});
  return response({error:"We could not send or verify your code. Please try again later."},503);
 }
}
