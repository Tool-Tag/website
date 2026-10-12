import { can } from "@/lib/auth/permissions";
import Link from "next/link";
import { requirePermission } from "@/lib/domain/context";
import { Heading, Panel } from "@/components/ui";
import { SupportConversation } from "@/components/support-conversation";
import { StatusRefresh } from "@/components/status-refresh";
import { denverDateTime } from "@/lib/domain/time";
import { supportEnabled, supportReplyEnabled } from "@/lib/integrations/support-gmail";
import { z } from "zod";
export const dynamic="force-dynamic";
export default async function Notifications({searchParams}:{searchParams:Promise<{tab?:string;id?:string}>}) {
 const {db,unit,access}=await requirePermission("support.inbox"),q=await searchParams;
 const tab=["support","hello","open","history"].includes(q.tab || "") ? q.tab!:"support";
 let list=db.from("support_conversations").select("*").eq("unit_id",unit).order("updated_at",{ascending:false}).limit(100);
 if(tab==="support" || tab==="hello")list=list.eq("status","New").eq("mailbox",tab);else list=list.eq("status",tab==="open" ? "Open":"Closed");
 const [result,state]=await Promise.all([list,db.rpc("support_integration_status")]);
 const selected=q.id && z.string().uuid().safeParse(q.id).success ? await db.from("support_conversations").select("*").eq("id",q.id).eq("unit_id",unit).maybeSingle():null;
 const conversation=selected?.data;
 const messages=conversation ? await db.from("support_messages").select("*").eq("conversation_id",conversation.id).order("sent_at").limit(200):null;
 const through=(messages?.data || []).filter(m=>m.direction==="Inbound").at(-1)?.sent_at;
 return <><Heading title="Notifications" subtitle="Support and Hello conversations"/><StatusRefresh/>
 {!supportEnabled() && <p className="notice">Gmail inbox is inactive. Existing conversations remain available; incoming mail will sync after setup.</p>}
 {state.data?.last_error && <p className="notice">Inbox sync needs attention: {state.data.last_error}. Existing customer notifications are unaffected.</p>}
 <p className="muted">Last inbox sync: {denverDateTime(state.data?.last_success)}</p>
 <nav className="actions support-tabs" aria-label="Inbox tabs">{[["support","Support"],["hello","Hello"],["open","Open cases"],["history","History"]].map(([key,label])=><Link key={key} className={`button ${tab===key ? "":"secondary"}`} href={`/app/notifications?tab=${key}`} aria-current={tab===key ? "page":undefined}>{label}</Link>)}</nav>
 <div className="support-layout"><Panel title="Conversations">{result.error ? <p className="notice">Inbox migration is not available yet.</p>:result.data?.length ? result.data.map(c=><Link className={`support-card ${conversation?.id===c.id ? "selected":""}`} key={c.id} href={`/app/notifications?tab=${tab}&id=${c.id}`}><strong>{c.case_code || "New email"} {c.unread_count>0 && <span className="badge">{c.unread_count} unread</span>}</strong><span>{c.sender_name || c.sender_email}</span><span>{c.subject}</span><small>{denverDateTime(c.updated_at)}</small></Link>):<p className="muted">No conversations in this tab.</p>}<p className="muted">Showing the 100 most recent conversations.</p></Panel>
 <Panel title={conversation?.case_code || "Conversation"}>{conversation ? <><p>{conversation.sender_email} · {conversation.mailbox}</p>{conversation.customer_id && can(access,"customers.view") && <Link href={`/app/customers/${conversation.customer_id}`}>Linked customer</Link>}
 {messages?.error ? <p className="notice">Messages could not load.</p>:(messages?.data || []).map(m=><article className={`support-message ${m.direction==="Outbound" ? "outbound":""}`} key={m.id}><strong>{m.direction==="Inbound" ? conversation.sender_email:"ToolTag reply"}</strong><small>{denverDateTime(m.sent_at)} · {m.delivery_status}</small><p>{m.subject}</p><pre>{m.body}</pre>{m.delivery_error && <p className="notice">{m.delivery_error} — check delivery before replying again.</p>}</article>)}
 {through && <SupportConversation key={conversation.id} id={conversation.id} through={new Date(through).toISOString()} closed={conversation.status==="Closed"} canClose={!!conversation.case_code} sendEnabled={supportReplyEnabled()}/>}</>:<p className="muted">Choose a conversation to read or reply.</p>}</Panel></div></>;
}
