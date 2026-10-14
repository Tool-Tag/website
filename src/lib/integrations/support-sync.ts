import type { SupabaseClient } from "@supabase/supabase-js";
import { SupportGmail, parseSupportMessage, supportEnabled, supportAckEnabled, type SupportReply } from "./support-gmail";
import { MailFailure } from "./gmail";
export async function syncSupportInbox(db: SupabaseClient, env: Record<string,string|undefined> = process.env, gmail = new SupportGmail(env)) {
 if (!supportEnabled(env)) return {status:"disabled",imported:0};
 const lease = await db.rpc("support_begin_sync");
 if (lease.error) return {status:"unavailable",imported:0};
 if (!lease.data) return {status:"busy",imported:0};
 let imported=0;const started=Date.now();
 try {
  const page=await gmail.list(lease.data.since,lease.data.page_token || undefined,lease.data.before);
  for (const entry of page.messages || []) {
   if(Date.now()-started>180000)throw new MailFailure("SUPPORT_SYNC_TIME_BUDGET");
   const parsed=parseSupportMessage(await gmail.get(entry.id),env);if (!parsed) continue;
   const result=await db.rpc("support_ingest",{p:parsed});if(result.error) throw new MailFailure("SUPPORT_PERSIST_FAILED");imported++;
  }
  if(supportAckEnabled(env)) {
   for(let i=0;i<10;i++) {
    if(Date.now()-started>180000)break;
    const ack=await db.rpc("support_claim_ack");if(ack.error)throw new MailFailure("SUPPORT_ACK_CLAIM_FAILED");if(!ack.data)break;
    const reply=ack.data as SupportReply;let status="Sent",providerId:string|null=null,thread:string|null=null,code:string|null=null;
    try{const sent=await gmail.send(reply);providerId=sent.id;thread=sent.threadId;}
    catch(error){code=error instanceof MailFailure?error.code:"GMAIL_DELIVERY_UNKNOWN";status=code==="GMAIL_DELIVERY_UNKNOWN"?"Unknown":"Failed";}
    const finish=await db.rpc("support_finish_reply",{p_id:reply.id,p_status:status,p_gmail_id:providerId,p_thread:thread,p_error:code});if(finish.error)throw new MailFailure("SUPPORT_ACK_FINISH_FAILED");
   }
  }
  // Reconcile ambiguous sends by deterministic Message-ID, never automatically resend them.
  const pending=await db.from("support_messages").select("id").in("delivery_status",["Sending","Unknown"]).lt("sent_at",new Date(Date.now()-60000).toISOString()).limit(10);
  if(pending.error) throw new MailFailure("SUPPORT_RECONCILE_FAILED");
  for(const reply of pending.data || []) {
   if(Date.now()-started>180000)throw new MailFailure("SUPPORT_SYNC_TIME_BUDGET");
   const sent=await gmail.findSent(reply.id);
   const r=await db.rpc("support_finish_reply",{p_id:reply.id,p_status:sent ? "Sent":"Unknown",p_gmail_id:sent?.id || null,p_thread:sent?.threadId || null,p_error:sent ? null:"GMAIL_DELIVERY_UNKNOWN"});
   if(r.error) throw new MailFailure("SUPPORT_RECONCILE_FAILED");
  }
  const end=await db.rpc("support_finish_sync",{p_lease:lease.data.lease,p_next:page.nextPageToken || null});
  if(end.error) throw new MailFailure("SUPPORT_CHECKPOINT_FAILED");
  return {status:"ok",imported,more:!!page.nextPageToken};
 }catch(error){
  const code=error instanceof MailFailure ? error.code:"SUPPORT_SYNC_FAILED";
  await db.rpc("support_finish_sync",{p_lease:lease.data.lease,p_next:null,p_error:code});
  return {status:code,imported};
 }
}
