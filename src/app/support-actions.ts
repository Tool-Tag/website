"use server";
import { requirePermission } from "@/lib/domain/context";
import { storageAdmin } from "@/lib/storage/admin";
import { SupportGmail, supportReplyEnabled, type SupportReply } from "@/lib/integrations/support-gmail";
import { MailFailure } from "@/lib/integrations/gmail";
import { revalidatePath } from "next/cache";
import { z } from "zod";
const uuid=z.string().uuid();
export async function markSupportRead(id:string,through:string) {
 const {db}=await requirePermission("support.inbox");
 if(!uuid.safeParse(id).success || !z.string().datetime().safeParse(through).success) return {error:"Invalid message."};
 const r=await db.rpc("support_mark_read",{p_id:id,p_through:through});
 return r.error ? {error:"Could not mark this conversation as read."}:{ok:true};
}
export async function closeSupportCase(id:string) {
 const {db}=await requirePermission("support.inbox");if(!uuid.safeParse(id).success)return {error:"Invalid case."};
 const r=await db.rpc("support_close",{p_id:id});revalidatePath("/app/notifications");
 return r.error ? {error:r.error.message}:{ok:true};
}
export async function replySupport(id:string,request:string,body:string) {
 const {db}=await requirePermission("support.inbox");
 if(!uuid.safeParse(id).success || !uuid.safeParse(request).success || !body.trim() || body.length>20000) return {error:"Enter a reply of up to 20,000 characters."};
 if(!supportReplyEnabled())return {error:"Support email sending is disabled. Configure Gmail read/send access and enable the inbox first."};
 // Verify private worker configuration before recording a reply; never send without a durable result path.
 let admin:ReturnType<typeof storageAdmin>;try{admin=storageAdmin();}catch{return {error:"Private inbox delivery storage is not configured."};}
 const prepared=await db.rpc("support_prepare_reply",{p_id:id,p_request:request,p_body:body});
 if(prepared.error || !prepared.data)return {error:prepared.error?.message || "Could not prepare reply."};
 const reply=prepared.data as SupportReply;
 let status="Sent",providerId:string|null=null,thread:string|null=null,errorCode:string|null=null;
 try{const sent=await new SupportGmail().send(reply);providerId=sent.id;thread=sent.threadId;}
 catch(error){errorCode=error instanceof MailFailure ? error.code:"GMAIL_DELIVERY_UNKNOWN";status=errorCode==="GMAIL_DELIVERY_UNKNOWN" ? "Unknown":"Failed";}
 const finish=await admin.rpc("support_finish_reply",{p_id:reply.id,p_status:status,p_gmail_id:providerId,p_thread:thread,p_error:errorCode});
 revalidatePath("/app/notifications");
 if(finish.error || status==="Unknown")return {error:"Delivery needs verification. Do not resend; the inbox worker will check Gmail."};
 if(status==="Failed")return {error:`Reply was not sent (${errorCode}). Your draft is retained below.`,retryable:true};
 return {ok:true};
}
