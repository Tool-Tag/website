import {SupportCaseModal} from "@/components/support-case-modal";
import Link from "next/link";
import {requirePermission} from "@/lib/domain/context";
import {Heading} from "@/components/ui";
import {SupportConversation} from "@/components/support-conversation";
import {NewSupportCase,type SupportDirectory} from "@/components/new-support-case";
import {StatusRefresh} from "@/components/status-refresh";
import {denverDateTime} from "@/lib/domain/time";
import {queueDays,urgency} from "@/lib/domain/urgent-attention";
import {supportReplyEnabled} from "@/lib/integrations/support-gmail";
import {z} from "zod";
import {paginateList} from "@/lib/domain/list-pagination";
export const dynamic="force-dynamic";
export default async function Support({searchParams}:{searchParams:Promise<{section?:string;tab?:string;origin?:string;id?:string;page?:string}>}){
 const {db,unit}=await requirePermission("support.inbox"),q=await searchParams;
 const questions=q.section==="questions",section=questions?"questions":"support";
 const resolved=q.tab==="resolved",origin=q.origin==="Inbox"||q.origin==="Job"?q.origin:"";
 const [result,directory]=await Promise.all([db.rpc("support_cases"),db.rpc("support_directory")]);if(result.error||directory.error)throw new Error("Could not load Support cases.");
 const choices=directory.data as SupportDirectory;
 type Case={id:string;status:string;origin:string;channel:string;mailbox:string;subject:string;case_code:string|null;sender_name:string;sender_email:string;job_id:string|null;updated_at:string;last_message:string|null;last_message_at:string|null;waiting_since:string|null};
 const now=new Date();
 const rows=((result.data??[]) as Case[]).filter(c=>(questions?c.mailbox==="hello":c.mailbox!=="hello")&&(resolved?c.status==="Closed":c.status!=="Closed")&&(!origin||resolved||c.origin===origin)).map(c=>{const days=c.waiting_since?queueDays(c.waiting_since,now,true):0;return {c,days,color:urgency("problem",days)};}).sort((a,b)=>({red:0,orange:1,green:2}[a.color]-{red:0,orange:1,green:2}[b.color])||b.days-a.days||Date.parse(b.c.updated_at)-Date.parse(a.c.updated_at)||a.c.id.localeCompare(b.c.id));
 const pagination=paginateList(rows,q.page);
 const pageUrl=(page:number,id?:string)=>{const params=new URLSearchParams({section,tab:resolved?"resolved":"open",page:String(page)});if(origin)params.set("origin",origin);if(id)params.set("id",id);return `/app/support?${params}`;};
 const selected=q.id&&z.string().uuid().safeParse(q.id).success?await db.from("support_conversations").select("*").eq("unit_id",unit).eq("id",q.id).maybeSingle():null;
 const c=selected?.data;const messages: {id:string;direction:string;body:string;sent_at:string;delivery_status:string;delivery_error:string|null;message_kind:string}[]=[];
 if(c){for(let from=0;;from+=500){const page=await db.from("support_messages").select("*").eq("conversation_id",c.id).order("sent_at").order("id").range(from,from+499);if(page.error)throw new Error("Could not load the conversation.");messages.push(...page.data);if(page.data.length<500)break;}}
 const through=messages.filter(m=>m.direction==="Inbound").at(-1)?.sent_at;
 const active=rows.find(row=>row.c.id===c?.id);const job=choices.jobs.find(j=>j.id===c?.job_id);
 return <><Heading title="Support" subtitle="Customer cases · Inbox, Job issues and phone calls"/><StatusRefresh/>
 <nav className="main-tab-list" aria-label="Support sections">
  <Link className={`main-tab ${questions?"":"active"}`} aria-current={!questions?"page":undefined} href="/app/support?section=support">Support</Link>
  <Link className={`main-tab ${questions?"active":""}`} aria-current={questions?"page":undefined} href="/app/support?section=questions">Questions</Link>
 </nav>
 <div className="support-status-toolbar">
  <nav className="folder-tab-list shop-folder-tabs" aria-label="Case status">
   <Link className={`folder-tab ${resolved?"":"active"}`} aria-current={!resolved?"page":undefined} href={`/app/support?section=${section}`}>Open</Link>
   <Link className={`folder-tab ${resolved?"active":""}`} aria-current={resolved?"page":undefined} href={`/app/support?section=${section}&tab=resolved`}>Resolved</Link>
  </nav>
  {!questions&&<div className="actions"><NewSupportCase directory={choices}/></div>}
 </div>
 <div className="shop-folder-panel support-case-panel">
 {!resolved&&!questions&&<nav className="main-tab-list" aria-label="Case origin">{["","Inbox","Job"].map(filter=><Link key={filter} className={`main-tab ${origin===filter?"active":""}`} aria-current={origin===filter?"page":undefined} href={`/app/support?section=support${filter?`&origin=${filter}`:""}`}>{filter||"All origins"}</Link>)}</nav>}
 <section className="support-case-list" aria-labelledby="support-list-title">
 <h2 id="support-list-title">{resolved?"Resolved cases":"Open cases"}</h2>
 <div className="support-list-head" aria-hidden="true"><span>Customer / Case</span><span>Subject</span><span>Job / Origin</span><span>Latest message</span><span>Waiting</span></div>
 {!rows.length&&<p>No cases in this view.</p>}
 <ul>{pagination.items.map(({c:row,color,days})=><li key={row.id}><Link className="support-list-row" href={pageUrl(pagination.page,row.id)}><strong><span className={`support-urgency-dot dot-${color}`} aria-label={`${color} urgency`}/> {row.sender_name||row.sender_email||"Customer"}<small>{questions?"General inquiry":row.case_code||"New email"}</small></strong><span>{row.subject}</span><span>{choices.jobs.find(j=>j.id===row.job_id)?.code||"No linked Job"}<small>{row.origin} · {row.channel}</small></span><span>{row.last_message?.slice(0,180)||"No messages"}</span><span>{days} business days<small>{denverDateTime(row.last_message_at)}</small></span></Link></li>)}</ul>
 </section>
 <p role="status">{pagination.total} case{pagination.total===1?"":"s"} · {pagination.start}–{pagination.end} shown</p>
 <nav className="actions pagination" aria-label="Support pages">{pagination.page>1?<Link className="button secondary" href={pageUrl(pagination.page-1)}>Previous</Link>:<button type="button" disabled>Previous</button>}<span>Page {pagination.page} of {pagination.pages}</span>{pagination.page<pagination.pages?<Link className="button secondary" href={pageUrl(pagination.page+1)}>Next</Link>:<button type="button" disabled>Next</button>}</nav>
 {c&&<SupportCaseModal returnTo={pageUrl(pagination.page)} key={c.id} section={section} name={c.sender_name||c.sender_email||"Customer"} reference={questions?c.subject:`${c.case_code||"New email"} · ${c.subject}`} job={job?.code||""}><p><span className={`support-urgency-dot dot-${active?.color??"green"}`}/> {active?.days??0} business days waiting</p>{job&&<Link href={`/app/jobs/${job.id}`}>View Job {job.code}</Link>}{c.contact_phone&&<p>Phone: {c.contact_phone}</p>}{!job&&c.job_reference&&<p>Submitted Job reference: {c.job_reference} · not verified</p>}<div className="support-thread">{messages.map(m=><article className={`support-message ${m.direction==="Outbound"?"outbound":""}`} key={m.id}><strong>{m.message_kind==="Acknowledgment"?"ToolTag · automatic acknowledgment":m.direction==="Inbound"?"Customer":"ToolTag"}</strong><small>{denverDateTime(m.sent_at)} · {m.delivery_status}</small><pre>{m.body}</pre>{m.delivery_error&&<p role="alert">{m.delivery_error}</p>}</article>)}</div>{!c.sender_email&&<p>Email reply unavailable: this customer has no email address.</p>}{through&&<SupportConversation key={c.id} id={c.id} through={new Date(through).toISOString()} closed={c.status==="Closed"} canClose={false} sendEnabled={!!c.sender_email&&supportReplyEnabled()}/>}</SupportCaseModal>}</div></>;
}
