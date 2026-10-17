"use client";
import Link from "next/link";
import {useId,useRef,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {useAccess} from "./permission-provider";
import {canAny} from "@/lib/auth/permissions";
import {lostStaffAction} from "@/app/lost-actions";
import {lostCanFinalize,type LostCase,type LostStatus} from "@/lib/domain/lost-flow";
import {denverDateTime} from "@/lib/domain/time";
import {money} from "@/lib/domain/money";

export function LostWorkspace({rows,canApprove}:{rows:LostCase[];canApprove:boolean}) {
 const [tab,setTab]=useState<LostStatus>("New");
 const list=rows.filter(row=>(row.status??"New")===tab).sort((a,b)=>Date.parse(tab==="History"?b.finalized_at??b.reported_at:a.reported_at)-Date.parse(tab==="History"?a.finalized_at??a.reported_at:b.reported_at));
 return <><nav className="main-tab-list" aria-label="Lost cases">{(["New","In Process","History"] as const).map(name=><button type="button" key={name} className={`main-tab ${tab===name?"active":""}`} aria-pressed={tab===name} onClick={()=>setTab(name)}>{name} ({rows.filter(r=>(r.status??"New")===name).length})</button>)}</nav>
 <section aria-label={`${tab} Lost cases`}><div className="lost-case-list">{!list.length&&<p>No {tab.toLowerCase()} cases.</p>}{list.map(row=><LostCaseRow key={row.id} row={row} canApprove={canApprove}/>)}</div></section></>;
}
function LostCaseRow({row,canApprove}:{row:LostCase;canApprove:boolean}) {
 const dialog=useRef<HTMLDialogElement>(null),waiting=useRef<HTMLDialogElement>(null);const id=useId();
 const access=useAccess(),router=useRouter();const manage=canAny(access,["jobs.manage","pr.returns"]);
 const [value,setValue]=useState(String(row.market_value??"")),[notes,setNotes]=useState(""),[error,setError]=useState("");const [pending,start]=useTransition();
 const status=row.status??"New";
 function run(action:"notify"|"approve"|"finalize") {setError("");start(async()=>{const result=await lostStaffAction(row.id,action,{market_value:value,notes});if(result.error)setError(result.error);else {dialog.current?.close();router.refresh();}});}
 return <div className="lost-case-entry">
 {status==="In Process"&&<p className="lost-response">Response: <strong>{row.customer_choice??"Waiting for customer response"}</strong></p>}
 <button type="button" className="lost-case-row blue-electric" aria-haspopup="dialog" onClick={()=>{setError("");if(status==="In Process"&&!row.customer_choice)waiting.current?.showModal();else dialog.current?.showModal();}}>
  <strong>{row.job}</strong><span>{row.customer}</span><span>{denverDateTime(row.reported_at)}</span><span>{status}</span>
 </button>
 <dialog ref={waiting} className="lost-case-modal" aria-label="Waiting for customer response"><h2>Waiting for customer response</h2><p>The customer has not chosen a resolution yet.</p><button type="button" className="secondary" onClick={()=>waiting.current?.close()}>Close</button></dialog>
 <dialog ref={dialog} className="lost-case-modal" aria-labelledby={id}>
  <header className="actions" style={{justifyContent:"space-between"}}><h2 id={id}>{row.job} · {row.customer}</h2><button type="button" className="secondary" disabled={pending} onClick={()=>dialog.current?.close()}>Close</button></header>
  <p>Lost ID: {row.id}</p><p>Status: {status}</p><p>Customer phone: {row.phone||"Not provided"}</p>
  <p>Driver: {row.driver} {row.driver_id?`· ${row.driver_id}`:""}</p><p>Driver contact: {row.driver_email||"Not provided"}</p>
  <p>Route: {row.route_date} · Reported: {denverDateTime(row.reported_at)}</p>
  <h3>Missing pieces</h3><ul>{(row.items??[]).map(i=><li key={i.id}>{i.sequence}. {i.article}</li>)}</ul><p style={{whiteSpace:"pre-wrap"}}>{row.explanation}</p>
  {status==="New"&&manage?<label>Total market value of missing items (USD)<input type="number" min="0.01" step="0.01" value={value} disabled={pending} onChange={e=>setValue(e.target.value)}/></label>:<p>Market value: {money(row.market_value)}</p>}
  {row.notified_at&&<p>Notification queued: {denverDateTime(row.notified_at)}</p>}
  {row.customer_choice&&<p>Response: <strong>{row.customer_choice}</strong> · {denverDateTime(row.responded_at)}</p>}
  {row.approved_at&&<p>Approved: {denverDateTime(row.approved_at)}</p>}
  {row.refund_id&&<p>Refund status: {row.refund_status??"Pending"}{canAny(access,["payments.refund","payments.view"])&&<> · <Link href="/app/refunds">Open Refunds</Link></>}</p>}
  {status==="New"&&manage&&<><p>Notify sends the customer an apology and a secure choice link. SMS requires an eligible phone and consent. The market value is frozen after notification.</p><button type="button" disabled={pending||!value} onClick={()=>run("notify")}>Notify</button></>}
  {status==="In Process"&&!row.approved_at&&row.customer_choice&&(canApprove?<button type="button" disabled={pending} onClick={()=>run("approve")}>Approved</button>:<p>Awaiting Owner or Manager approval.</p>)}
  {status==="In Process"&&row.approved_at&&manage&&<><label>Resolution details<textarea value={notes} maxLength={5000} disabled={pending} onChange={e=>setNotes(e.target.value)} placeholder={row.customer_choice==="Replace Item"?"Record the replacement provided and how delivery was completed.":"Record the completed refund resolution."}/></label>{!lostCanFinalize({...row,status})&&<p>Complete the linked Refund before finalizing this case.</p>}<button type="button" disabled={pending||!notes.trim()||!lostCanFinalize({...row,status})} onClick={()=>run("finalize")}>Process / Finalize</button></>}
  {status==="History"&&<><p>Completed: {denverDateTime(row.finalized_at)}</p><p>{row.resolution_notes}</p><p>This record is read-only.</p></>}
  {error&&<p className="notice error" role="alert">{error}</p>}
 </dialog></div>;
}
