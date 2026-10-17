import Link from "next/link";
import Image from "next/image";
import {randomUUID} from "node:crypto";
import {requirePermission} from "@/lib/domain/context";
import {can} from "@/lib/auth/permissions";
import {Panel, Empty, Badge} from "@/components/ui";
import {RefundCaseModal} from "@/components/refund-case-modal";
import {RefundCreate, RefundUpdate, type RefundJob} from "@/components/refund-forms";
import {RefundProofUpload} from "@/components/refund-proof-upload";
import {RefundStatusTabs} from "@/components/refund-status-tabs";
import {money} from "@/lib/domain/money";
import {denverDateTime} from "@/lib/domain/time";
import {compareRefundUrgency,refundAttention,refundEligibility,refundCompletionLabel,refundAmountRemaining} from "@/lib/domain/refund-flow";

import {decryptLostPaymentDetails,type LostPaymentDetails} from "@/lib/security/lost-payment-details";

export async function RefundsPanel({jobId,view="cases",requestIds}:{jobId?:string;view?:"cases"|"execution";requestIds?:string[]}) {
 const {db,unit,access}=await requirePermission("payments.refund","payments.view");
 let query=db.from("refund_requests").select("*").eq("unit_id",unit).order("requested_at",{ascending:false});
 if(requestIds)query=query.in("id",requestIds).order("id",{ascending:false});
 if(jobId)query=query.eq("job_id",jobId);
 if(view==="execution")query=query.eq("status","Approved");
 const [{data:requests,error},{data:choices,error:choiceError},{data:accountChoices,error:accountError},{data:approver,error:approverError}]=await Promise.all([query,db.rpc("refund_job_choices"),view==="execution"?db.rpc("refund_account_choices"):Promise.resolve({data:[],error:null}),db.rpc("refund_can_approve")]);
 if(error||choiceError||accountError||approverError)throw new Error(error?.message??choiceError?.message??accountError?.message??approverError?.message);
 const jobs=(choices??[]) as RefundJob[],manage=can(access,"payments.refund"),now=new Date();
 const ids=(requests??[]).map(r=>r.id);
 const {data:documents,error:docError}=ids.length?await db.from("documents").select("id,file_name,refund_request_id,storage_status,type,refund_method,mime_type").eq("unit_id",unit).in("refund_request_id",ids):{data:[],error:null};
 if(docError)throw new Error(docError.message);
 const payout=new Map<string,LostPaymentDetails>();
 if(manage)await Promise.all((requests??[]).filter(r=>r.source_kind==="Lost"&&!["Completed","Rejected"].includes(r.status)).map(async r=>{const {data,error}=await db.rpc("lost_refund_payment_details",{p_refund:r.id});if(!error&&data){try{payout.set(r.id,decryptLostPaymentDetails(data,r.source_id));}catch{/* Never expose ciphertext or key errors. */}}}));
 const paymentDetails=(id:string)=>{const p=payout.get(id);return p?<section><h3>Customer payment instructions</h3><p>Method: {p.method} · Holder: {p.holder}</p>{p.routing&&<p>Routing: {p.routing}</p>}{p.account&&<p>Account: {p.account}</p>}{p.handle&&<p>Payment identifier: {p.handle}</p>}{p.address&&<p>Mailing address: {p.address}</p>}</section>:null;};
 const render=(list:NonNullable<typeof requests>,modal=false)=><div className="stack">
  {list.length===0&&!modal&&<Empty>{view==="execution"?"No approved refunds awaiting manual issuance.":"No refunds for this selection."}</Empty>}
  {list.map(r=>{
   const job=jobs.find(j=>j.id===r.job_id),title=`${job?.code??r.job_id} · ${money(r.amount)}`;
   const files=(documents??[]).filter(d=>d.refund_request_id===r.id&&d.storage_status==="stored");
   const attention=refundAttention(r.confirmed_at,now);
   const remaining=refundAmountRemaining(String(r.amount),String(r.processed_amount));
   const evidence=<section aria-label="Refund evidence"><h3>Evidence</h3>
     {files.length===0&&<p>No stored screenshots.</p>}
     {files.map(f=><div key={f.id}><p><Link href={`/app/documents/${f.id}/download`} target="_blank" rel="noopener noreferrer">{f.file_name}{f.refund_method?` · ${f.refund_method}`:""}</Link></p>{["image/png","image/jpeg","image/webp"].includes(f.mime_type)&&<details><summary>Preview screenshot</summary><Image unoptimized src={`/app/documents/${f.id}/download`} alt={`Refund screenshot: ${f.file_name}`} width={600} height={400} style={{width:"100%",height:"auto",maxHeight:"22rem",objectFit:"contain"}}/></details>}</div>)}
    </section>;
   if(view==="execution")return <div key={r.id} id={`refund-${r.id}`}><Panel title={`${job?.customer_name??"Customer"} · ${title}`}>
    <Badge>Approved</Badge><p>Approved: {denverDateTime(r.approved_at)} · Original payment method: {r.original_method??"Unconfirmed"}</p>
    <p>Approved refund: {money(r.amount)} · Previously issued: {money(r.processed_amount)} · Amount to issue: {money(remaining)}</p>
    {paymentDetails(r.id)}{manage&&r.source_kind==="Lost"&&!payout.has(r.id)&&!["Completed","Rejected"].includes(r.status)&&<p role="alert">Secure customer payment instructions are unavailable. Check the encryption-key configuration before issuing this refund.</p>}
    {evidence}
    {manage?<><h3>Execute manual refund</h3><RefundProofUpload job={r.job_id} id={r.id} method={r.method}/><RefundUpdate id={r.id} kind="complete" amount={remaining} method={r.method} proofs={files} accounts={accountChoices??[]} originalAccount={job?.original_account_id}/></>:<p>Read-only access. Refund permission is required to record issuance.</p>}
    <Link href="/app/refunds">Open refund case management</Link>
   </Panel></div>;
   const details=<Panel title={modal?undefined:`${job?.customer_name??"Customer"} · ${title}`}>
    {!modal&&<Badge>{r.status}</Badge>}
    <section aria-label="Refund details"><h3>Details</h3>
     <p>Reason: {r.reason} · Source: {r.source_kind}</p>
     <p>Origin event: {r.issue_event??"Source obligation — review required"} · {denverDateTime(r.issue_event_at)}</p>
     <p>Reported: {denverDateTime(r.reported_at)} · Requested: {denverDateTime(r.requested_at)}</p>
     <p>Eligibility check: {r.source_kind==="Lost"?"Lost item market-value compensation — independent of service payments":refundEligibility(r.issue_event_at,r.reported_at)}</p>
     {r.confirmed_at&&<p>Eligibility confirmed: {denverDateTime(r.confirmed_at)} · Process {r.process_not_before}–{r.process_due} (business days)</p>}
     {r.approved_at&&<p>Approved: {denverDateTime(r.approved_at)}</p>}
     {r.status==="Rejected"&&<p>Rejected: {denverDateTime(r.rejected_at)} · Reason: {r.rejection_reason}</p>}
     {r.status==="Issued"&&<p>Awaiting customer acknowledgment until {denverDateTime(r.acknowledgment_deadline)} (five calendar days from issuance).</p>}
     {r.status==="Completed"&&<p>Completion method: {refundCompletionLabel(r.completion_reason,r.completion_channel)} · {denverDateTime(r.completed_at||r.processed_at)}{r.completed_by&&` · Recorded by: ${r.completed_by}`}</p>}
     {r.completion_notes&&<p>Receipt confirmation: {r.completion_notes}</p>}
    </section>
    <section aria-label="Refund payment"><h3>Payment</h3>
     <p>Original method: {r.original_method??"Unconfirmed"} · Refund method: {r.method??"Selection required"}</p>
     <dl><dt>Requested refund</dt><dd>{money(r.amount)}</dd><dt>Issued</dt><dd>{money(r.processed_amount)}</dd><dt>Not issued</dt><dd>{money(remaining)}</dd></dl>
     <p>Accounting period: {String(r.accounting_period).slice(0,7)}</p>
     {r.processed_at&&<p>Issued: {denverDateTime(r.processed_at)} · By: {r.confirmation_snapshot?.processor_name??r.processed_by} · Reference: {r.reference}</p>}
     {r.confirmation_snapshot&&<p>Recorded payment: {money(r.confirmation_snapshot.amount)} · {r.confirmation_snapshot.method} · {r.confirmation_snapshot.job_code} / {r.confirmation_snapshot.quote_code}</p>}
    </section>
    {paymentDetails(r.id)}{manage&&r.source_kind==="Lost"&&!payout.has(r.id)&&!["Completed","Rejected"].includes(r.status)&&<p role="alert">Secure customer payment instructions are unavailable. Check the encryption-key configuration before issuing this refund.</p>}
    {evidence}
    {manage&&["In Review","Approved","Issued"].includes(r.status)&&<section aria-label="Refund actions"><h3>Actions</h3>
     {r.status==="In Review"&&<>
      {!r.confirmed_at&&<RefundUpdate id={r.id} kind="confirm" review={r.requires_review}/>}
      {r.confirmed_at&&(approver?<RefundUpdate id={r.id} kind="approve"/>:<p>Awaiting Owner or Manager approval.</p>)}
      <details><summary>Reject refund</summary><RefundUpdate id={r.id} kind="reject"/></details>
     </>}
     {r.status==="Approved"&&<p>Ready for manual execution. <Link className="button" href={`/app/finance/refunds#refund-${r.id}`}>Execute in Finance → Refunds</Link></p>}
     {r.status==="Issued"&&<details><summary>Record customer receipt by phone or email</summary><RefundUpdate id={r.id} kind="acknowledge"/></details>}
    </section>}
    <section aria-label="Refund notes"><h3>Notes</h3><p style={{whiteSpace:"pre-wrap"}}>{r.notes||"No notes."}</p>
     {manage&&["Pending","In Review","Approved","Issued"].includes(r.status)&&<details><summary>Add note</summary><RefundUpdate id={r.id} kind="note"/></details>}
    </section>
   </Panel>;
   return modal?<RefundCaseModal key={r.id} id={r.id} title={title} customer={job?.customer_name??"Customer"} status={r.status} reason={r.reason} requested={denverDateTime(r.requested_at)} days={attention.days} color={attention.color} canReview={manage}>{details}</RefundCaseModal>:<div key={r.id}>{details}</div>;
  })}
 </div>;
 if(view==="execution")return <><p>Only approved refunds are shown here. After issuance, follow customer confirmation in <Link href="/app/refunds">Refunds</Link>.</p>{render(requests??[])}</>;
 const active=(requests??[]).filter(r=>["Pending","In Review","Approved","Issued"].includes(r.status)).sort((a,b)=>compareRefundUrgency(a,b,now));
 const history=(requests??[]).filter(r=>["Completed","Rejected"].includes(r.status)).sort((a,b)=>Date.parse(b.completed_at||b.rejected_at||b.processed_at||b.requested_at)-Date.parse(a.completed_at||a.rejected_at||a.processed_at||a.requested_at));
 return <RefundStatusTabs counts={{Pending:active.filter(r=>r.status==="Pending").length,"In Review":active.filter(r=>r.status==="In Review").length,Approved:active.filter(r=>r.status==="Approved").length,Issued:active.filter(r=>r.status==="Issued").length}} historyCount={history.length}
  create={manage&&<details className="panel"><summary>New refund</summary><RefundCreate jobs={jobId?jobs.filter(j=>j.id===jobId):jobs} jobId={jobId} requestKey={randomUUID()}/></details>}
  history={render(history)}>{render(active,true)}</RefundStatusTabs>;
}
