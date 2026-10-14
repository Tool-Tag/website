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
 const r=await db.rpc("support_close",{p_id:id});revalidatePath("/app/notifications");revalidatePath("/app/support");
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
 revalidatePath("/app/notifications");revalidatePath("/app/support");
 if(finish.error || status==="Unknown")return {error:"Delivery needs verification. Do not resend; the inbox worker will check Gmail."};
 if(status==="Failed")return {error:`Reply was not sent (${errorCode}). Your draft is retained below.`,retryable:true};
 return {ok:true};
}
export async function createSupportCase(request:string,customer:string,job:string,subject:string,body:string){
 const {db}=await requirePermission("support.inbox");
 if(!uuid.safeParse(request).success||!uuid.safeParse(customer).success||(job&&!uuid.safeParse(job).success))return {error:"Choose a valid customer and Job."};
 const {data,error}=await db.rpc("support_create_case",{p_request:request,p_customer:customer,p_job:job||null,p_subject:subject,p_body:body});
 revalidatePath("/app/support");return error?{error:error.message}:{id:data as string};
}
export async function supportClosureProtocol(id:string,request:string,completed:boolean):Promise<{error?:string;ok?:boolean;waiting?:boolean;retryable?:boolean}>{
 const {db}=await requirePermission("support.inbox");
 if(!uuid.safeParse(id).success||!uuid.safeParse(request).success)return {error:"Invalid case."};
 const body=completed?"It was a pleasure helping you. Thank you for choosing ToolTag! If you need anything else, we are always here to help. We will now close this conversation.":"Is there anything else we can help you with? Please let us know before we close this conversation.";
 const existing=await db.from("support_messages").select("delivery_status,body").eq("id",request).eq("conversation_id",id).maybeSingle();
 if(existing.error)return {error:"Could not verify the closure message."};
 if(existing.data&&existing.data.delivery_status!=="Sent")return {error:"The closure message still needs delivery verification. Do not resend."};
 if(existing.data&&!existing.data.body.startsWith(body))return {error:"Invalid closure message."};
 if(!existing.data){const sent=await replySupport(id,request,body);if(sent.error)return sent;}
 if(!completed)return {ok:true,waiting:true};
 const {error}=await db.rpc("support_resolve_protocol",{p_id:id,p_final:request});revalidatePath("/app/support");revalidatePath("/app/notifications");return error?{error:error.message}:{ok:true};
}
