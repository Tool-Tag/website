"use client";
import {HexModalFrame,ModalActions} from "./hex-modal-frame";

import {ModalClose} from "./modal-close";
import {DialogClose} from "./dialog-close";
import {DriverLossOwnerControls} from "./driver-loss-owner-controls";
import {MovementForm} from "./movement-form";
import Link from "next/link";
import {useId,useRef,useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {useAccess} from "./permission-provider";
import {canAny} from "@/lib/auth/permissions";
import {lostStaffAction} from "@/app/lost-actions";
import {lostCanFinalize,type LostCase,type LostStatus,type LostExpenseOptions} from "@/lib/domain/lost-flow";
import {denverCalendarDate,denverDateTime} from "@/lib/domain/time";
import {money} from "@/lib/domain/money";

export function LostWorkspace({rows,canApprove,expenseOptions}:{rows:LostCase[];canApprove:boolean;expenseOptions:LostExpenseOptions|null}) {
 const [tab,setTab]=useState<LostStatus>("New");
 const list=rows.filter(row=>(row.status??"New")===tab).sort((a,b)=>Date.parse(tab==="History"?b.finalized_at??b.reported_at:a.reported_at)-Date.parse(tab==="History"?a.finalized_at??a.reported_at:b.reported_at));
 return <section className="panel hex-list-workspace"><header className="hex-panel-head"><nav className="main-tab-list" aria-label="Lost cases">{(["New","In Process","History"] as const).map(name=><button type="button" key={name} className={`main-tab ${tab===name?"active":""}`} aria-pressed={tab===name} onClick={()=>setTab(name)}>{name} <span className="tab-count">{rows.filter(r=>(r.status??"New")===name).length}</span></button>)}</nav></header>
 <section aria-label={`${tab} Lost cases`}><div className="lost-case-list"><div className="lost-list-head"><span>Case / Job</span><span>Customer</span><span>Item</span><span>Reported</span><span>Status</span><span aria-hidden="true"/></div>{!list.length&&<p>No {tab.toLowerCase()} cases.</p>}{list.map(row=><LostCaseRow key={row.id} row={row} canApprove={canApprove} expenseOptions={expenseOptions}/>)}</div></section></section>;
}
function LostCaseRow({row,canApprove,expenseOptions}:{row:LostCase;canApprove:boolean;expenseOptions:LostExpenseOptions|null}) {
 const dialog=useRef<HTMLDialogElement>(null),waiting=useRef<HTMLDialogElement>(null);const id=useId();
 const confirmation=useRef<HTMLDialogElement>(null),expense=useRef<HTMLDialogElement>(null);
 const access=useAccess(),router=useRouter();const manage=canAny(access,["jobs.manage","pr.returns"]);
 const [value,setValue]=useState(row.market_value ?? ""),[notes,setNotes]=useState(""),[error,setError]=useState("");const [pending,start]=useTransition();
 const status=row.status??"New";
 function run(action:"notify"|"approve"|"finalize") {setError("");start(async()=>{const result=await lostStaffAction(row.id,action,{market_value:value,notes});if(result.error)setError(result.error);else {dialog.current?.close();router.refresh();}});}
 return <div className="lost-case-entry">
 {status==="In Process"&&<p className="lost-response">Response: <strong>{row.customer_choice??"Waiting for customer response"}</strong></p>}
 <button type="button" className="lost-case-row blue-electric" aria-haspopup="dialog" onClick={()=>{setError("");if(status==="In Process"&&!row.customer_choice)waiting.current?.showModal();else dialog.current?.showModal();}}>
  <strong><span className="lost-case-code">Lost · {row.job}</span></strong><span>{row.customer}</span><span className="lost-item-summary">{row.items?.[0]?.article||"Item details in case"}{(row.items?.length??0)>1&&` +${row.items.length-1}`}</span><span className="lost-reported">{denverDateTime(row.reported_at)}</span><span className="badge">{status}{row.missing_receipt&&" · Missing Receipt"}</span><span className="row-chevron" aria-hidden="true">›</span>
 </button>
 <dialog ref={waiting} className="hex-dialog lost-case-modal" aria-label="Waiting for customer response"><HexModalFrame><h2>Waiting for customer response</h2><p>The customer has not chosen a resolution yet.</p><ModalClose type="button" className="secondary modal-close" onClick={()=>waiting.current?.close()} aria-label="Close dialog">×</ModalClose></HexModalFrame></dialog>
 <dialog ref={dialog} className="hex-dialog lost-case-modal" aria-labelledby={id}><HexModalFrame>
  <header className="actions" style={{justifyContent:"space-between"}}><div><p className="eyebrow">Lost · Case detail</p><h2 id={id}>{row.job}</h2><p className="muted">{row.customer}</p></div><ModalClose type="button" className="secondary modal-close" disabled={pending} onClick={()=>dialog.current?.close()} aria-label="Close dialog">×</ModalClose></header>
  <dl className="hex-detail-grid"><div><dt>Status</dt><dd>{status}</dd></div><div><dt>Reported</dt><dd>{denverDateTime(row.reported_at)}</dd></div><div><dt>Customer phone</dt><dd>{row.phone||'Not provided'}</dd></div><div><dt>Driver</dt><dd>{row.driver||'Unassigned'}</dd></div><div><dt>Driver contact</dt><dd>{row.driver_email||'Not provided'}</dd></div><div><dt>{row.route_window_start ? "Route window start" : "Route date"}</dt><dd>{row.route_window_start ? denverDateTime(row.route_window_start) : denverCalendarDate(row.route_date)}</dd></div><div className="wide"><dt>Case reference</dt><dd>Lost · {row.job}</dd></div><div className="wide"><dt>Client choice</dt><dd>{row.customer_choice||'Waiting for customer response'}</dd></div></dl>
  <h3>Missing pieces</h3><ul>{(row.items??[]).map(i=><li key={i.id}>{i.sequence}. {i.article}</li>)}</ul><p style={{whiteSpace:"pre-wrap"}}>{row.explanation}</p>
  {status==="New"&&manage?<label>Total market value of missing items (USD)<input type="text" inputMode="decimal" value={value} disabled={pending} onChange={e=>setValue(e.target.value)}/></label>:<p>Market value: {money(row.market_value)}</p>}
  {access.owner&&row.driver_id&&(row.driver_agreements??[]).length>0&&<section><h3>Driver agreements</h3><p>New assignments: {row.driver_eligible?"Eligible":"Blocked"}</p>{row.driver_agreements?.map(a=><details key={a.id}><summary>Version {a.document_version} · {a.cost_final?"Final cost":"Initial notice"} · {a.accepted_at?"Accepted":"Awaiting acceptance"}</summary><p style={{whiteSpace:"pre-wrap"}}>{a.document_text}</p></details>)}<DriverLossOwnerControls driver={row.driver_id}/></section>}
  {row.notified_at&&<p>Notification queued: {denverDateTime(row.notified_at)}</p>}
  {row.customer_choice&&<p>Response: <strong>{row.customer_choice}</strong> · {denverDateTime(row.responded_at)}</p>}
  {row.approved_at&&<p>Approved: {denverDateTime(row.approved_at)}</p>}
  {row.customer_choice==="Refund money"&&!row.refund_id&&<p>Waiting for the customer to submit secure payment details. The Pending Refund will be created after submission.</p>}
  {row.refund_id&&<p>Refund status: {row.refund_status??"Pending"}{canAny(access,["payments.refund","payments.view"])&&<> · <Link href="/app/refunds">Open Refunds</Link></>}</p>}
  {status==="New"&&manage&&<><p>Notify sends the customer an apology and a secure choice link. SMS requires an eligible phone and consent. The market value is frozen after notification.</p><ModalActions><button type="button" disabled={pending||!value} onClick={()=>run("notify")}>Notify client</button></ModalActions></>}
  {status==="In Process"&&!row.approved_at&&row.customer_choice&&(canApprove?<ModalActions><button type="button" disabled={pending} onClick={()=>run("approve")}>Approved</button></ModalActions>:<p>Awaiting Owner or Manager approval.</p>)}
  {row.replacement_at_shop_at&&<p>Replacement confirmed at shop: {denverDateTime(row.replacement_at_shop_at)}</p>}
  {row.missing_receipt&&<p className="notice" role="status">Missing Receipt</p>}
  {row.replacement_expense_id&&<p>Replacement expense: {access.owner||canAny(access,["payments.view"])?<Link href={`/app/finance/transactions/${row.replacement_expense_id}`}>View transaction</Link>:"Recorded"}</p>}
  {status==="In Process"&&row.approved_at&&manage&&<>
   {row.customer_choice==="Replace Item"&&!row.replacement_expense_id&&<><ModalActions><button type="button" disabled={pending||!expenseOptions} onClick={()=>confirmation.current?.showModal()}>Process</button></ModalActions>{!expenseOptions&&<p>Owner access and available Finance accounts/categories are required to record the replacement expense.</p>}</>}
   {row.customer_choice==="Refund money"&&row.refund_id&&row.refund_status!=="Completed"&&<><p>Process the linked refund through the standard Refunds workflow. This case moves to History when the refund is issued.</p>{canAny(access,["payments.refund","payments.view"])&&<Link className="button" href="/app/refunds">Process</Link>}</>}
   {lostCanFinalize({...row,status})&&<><label>Resolution details<textarea value={notes} maxLength={5000} disabled={pending} onChange={e=>setNotes(e.target.value)} placeholder={row.customer_choice==="Replace Item"?"Record the replacement ready at the shop. Finalize notifies the customer to choose shop pickup or free delivery.":"Record the completed refund resolution."}/></label><ModalActions><button type="button" disabled={pending||!notes.trim()} onClick={()=>run("finalize")}>Finalize</button></ModalActions></>}
  </>}

  {status==="History"&&<><p>Completed: {denverDateTime(row.finalized_at)}</p><p>{row.resolution_notes}</p><p>This record is read-only.</p></>}
  {error&&<p className="notice error" role="alert">{error}</p>}
 </HexModalFrame></dialog>
 <dialog ref={confirmation} className="hex-dialog lost-case-modal" aria-label="Confirm replacement at shop"><HexModalFrame><DialogClose/><h2>Make sure the replacement is already at the shop</h2><p>Do not continue until the replacement is physically at the shop.</p><ModalActions><button type="button" disabled={pending} onClick={()=>{setError("");start(async()=>{const result=await lostStaffAction(row.id,"confirm-replacement");if(result.error)setError(result.error);else{confirmation.current?.close();expense.current?.showModal();router.refresh();}});}}>Confirmed</button><button type="button" className="secondary" disabled={pending} onClick={()=>confirmation.current?.close()}>Not yet</button></ModalActions>{error&&<p role="alert" className="notice error">{error}</p>}</HexModalFrame></dialog>
 <dialog ref={expense} className="hex-dialog lost-case-modal" aria-label="Record replacement expense"><HexModalFrame><header className="actions" style={{justifyContent:"space-between"}}><h2>Record replacement expense · {row.job}</h2><ModalClose type="button" className="secondary modal-close" onClick={()=>expense.current?.close()} aria-label="Close dialog">×</ModalClose></header>{expenseOptions&&<MovementForm requestId={row.id} lostCaseId={row.id} defaultType="EXPENSE" accounts={expenseOptions.accounts} categories={expenseOptions.categories} vendors={expenseOptions.vendors} sales={[]} expenses={[]} collections={[]} destinationAccounts={[]} onSaved={()=>{expense.current?.close();router.refresh();}}/>}</HexModalFrame></dialog>
 </div>;
}
