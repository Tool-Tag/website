import {NextRequest,NextResponse} from "next/server";
import {randomUUID,createHash} from "node:crypto";
import {z} from "zod";
import {storageAdmin} from "@/lib/storage/admin";
import {SMS_CONSENT_DISCLOSURE,SMS_POLICY_ACCEPTANCE} from "@/lib/domain/sms-consent";
export const dynamic="force-dynamic";
const schema=z.object({mailbox:z.enum(["support","hello"]),name:z.string().trim().min(1).max(150),email:z.string().trim().email().max(254),phone:z.string().trim().max(30).default(""),job:z.string().trim().max(80).default(""),message:z.string().trim().min(1).max(20000),sms_opt_in:z.boolean().default(false),policies_accepted:z.boolean().default(false)}).refine(p=>!p.sms_opt_in||!!p.phone&&p.policies_accepted,{message:"To opt in to SMS, provide a phone number and accept Terms and Privacy."});
const cookie=(mailbox:string)=>`tooltag_help_${mailbox}_nonce`;
const respond=(body:unknown,status=200)=>NextResponse.json(body,{status,headers:{"Cache-Control":"private, no-store"}});
export async function GET(request:NextRequest){
 const mailbox=request.nextUrl.searchParams.get("mailbox");if(mailbox!=="support"&&mailbox!=="hello")return respond({error:"Invalid form."},400);
 const token=randomUUID();const response=respond({token});response.cookies.set(cookie(mailbox),token,{httpOnly:true,sameSite:"strict",secure:request.nextUrl.protocol==="https:",maxAge:3600,path:"/api/help-message"});return response;
}
export async function POST(request:NextRequest){
 if(request.headers.get("origin")!==request.nextUrl.origin)return respond({error:"Invalid form origin."},403);
 if(Number(request.headers.get("content-length")||0)>100000)return respond({error:"Message is too large."},413);
 try{
 const text=await request.text();if(text.length>100000)return respond({error:"Message is too large."},413);const raw=JSON.parse(text);
 const data=schema.safeParse(raw);if(!data.success)return respond({error:data.error.issues[0]?.message||"Check your message."},400);
 if(!z.string().uuid().safeParse(raw.token).success||raw.token!==request.cookies.get(cookie(data.data.mailbox))?.value)return respond({error:"Your form session expired. Reopen the form and try again."},409);
 if(raw.website)return respond({reference:"Message received"});
 const payload={...data.data,sms_disclosure:SMS_CONSENT_DISCLOSURE,policy_disclosure:SMS_POLICY_ACCEPTANCE};
 const ip=request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()||request.headers.get("x-real-ip")||"unknown";
 const network=createHash("sha256").update((process.env.GET_TAGGED_RATE_SALT||"tooltag-help")+":"+ip).digest("hex");
 const hash=createHash("sha256").update(JSON.stringify(payload)).digest("hex");
 const result=await storageAdmin().rpc("submit_help_message",{p_request:raw.token,p_network:network,p_hash:hash,p:payload});
 if(result.error)return respond({error:result.error.message.includes("rate limit")?"Too many messages. Please try again later.":"We could not save your message. Please try again."},result.error.message.includes("rate limit")?429:400);
 return respond(result.data);
 }catch{return respond({error:"We could not submit your message. Please try again later."},503);}
}
