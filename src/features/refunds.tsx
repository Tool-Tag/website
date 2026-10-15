import Link from "next/link";
import {RefundCaseModal} from "@/components/refund-case-modal";
import { randomUUID } from "node:crypto";
import { requirePermission } from "@/lib/domain/context";
import { can } from "@/lib/auth/permissions";
import { Panel, Empty, Badge } from "@/components/ui";
import { RefundCreate, RefundUpdate, type RefundJob } from "@/components/refund-forms";
import {RefundProofUpload} from "@/components/refund-proof-upload";
import {JobTabs} from "@/components/job-tabs";
import { money } from "@/lib/domain/money";
import { denverDateTime } from "@/lib/domain/time";
export async function RefundsPanel({ jobId }: {
    jobId?: string;
}) {
    const { db, unit, access } = await requirePermission("payments.refund", "payments.view");
    let query = db.from("refund_requests").select("*").eq("unit_id", unit).order("requested_at", { ascending: false });
    if (jobId)
        query = query.eq("job_id", jobId);
    const [{ data: requests, error }, { data: choices, error: choiceError }, { data: accountChoices, error: accountError }] = await Promise.all([query, db.rpc("refund_job_choices"), db.rpc("refund_account_choices")]);
    if (error || choiceError || accountError)
        throw new Error(error?.message ?? choiceError?.message ?? accountError?.message);
    const jobs = (choices ?? []) as RefundJob[];
    const {data:approver}=await db.rpc("refund_can_approve");
    const manage = can(access, "payments.refund");
    const ids = (requests ?? []).map(r => r.id);
    const { data: documents, error: docError } = ids.length ? await db.from("documents").select("id,file_name,refund_request_id,storage_status,type,refund_method").eq("unit_id", unit).in("refund_request_id", ids) : { data: [], error: null };
    if (docError)
        throw new Error(docError.message);
    const render=(list:NonNullable<typeof requests>, modal=false)=><div className="stack">{list.length===0&&<Empty>No refunds for this selection.</Empty>}{list.map(r => {
            const job = jobs.find(j => j.id === r.job_id);
            const files = (documents ?? []).filter(d => d.refund_request_id === r.id && d.storage_status === "stored");
            const details = <Panel title={`${job?.code ?? r.job_id} · ${money(r.amount)}`}>
 <Badge>{r.status}</Badge>{r.approved_at&&<p>Approved: {denverDateTime(r.approved_at)}</p>}{r.status==="Issued"&&<p>Awaiting customer acknowledgment. Deadline: {denverDateTime(r.acknowledgment_deadline)}</p>}{r.status==="Completed"&&<p>Completed: {denverDateTime(r.completed_at||r.processed_at)} · {r.completion_reason||"Existing completed refund"}</p>}<p>{r.reason} · {r.source_kind} · Issued: {money(r.processed_amount)}</p><p>Original method: {r.original_method ?? "Unconfirmed"} · Refund method: {r.method ?? "Selection required"}</p>
 <p>Requested: {denverDateTime(r.requested_at)} · Reported: {denverDateTime(r.reported_at)}</p>
 {r.issue_event && <p>Issue event: {r.issue_event} · {denverDateTime(r.issue_event_at)}</p>}
 <p>Accounting period: {String(r.accounting_period).slice(0, 7)}</p>
 {r.confirmed_at && <p>Eligibility confirmed: {denverDateTime(r.confirmed_at)} · Process {r.process_not_before}–{r.process_due} (business days)</p>}
 {r.processed_at && <p>Processed: {denverDateTime(r.processed_at)} · By: {r.confirmation_snapshot?.processor_name ?? r.processed_by} · Reference: {r.reference}</p>}
 {r.notes && <p>{r.notes}</p>}
 {files.map(f => <p key={f.id}><Link href={`/app/documents/${f.id}/download`} target="_blank">Proof: {f.file_name}</Link></p>)}
 {r.confirmation_snapshot && <p className="notice success">Confirmation: {money(r.confirmation_snapshot.amount)} · {r.confirmation_snapshot.method} · {denverDateTime(r.confirmation_snapshot.processed_at)} · {r.confirmation_snapshot.job_code} / {r.confirmation_snapshot.quote_code} · Reference {r.confirmation_snapshot.reference}</p>}
 {manage && ["Pending","In Review","Approved"].includes(r.status) && <>

 {r.status==="In Review"&&!r.confirmed_at && <RefundUpdate id={r.id} kind="confirm" review={r.requires_review}/>}
 {r.status==="In Review"&&r.confirmed_at&&approver&&<RefundUpdate id={r.id} kind="approve"/>}{r.status==="In Review"&&r.confirmed_at&&!approver&&<p>Awaiting Owner or Manager approval.</p>}
 {r.status==="Approved"&&<details><summary>Upload refund screenshot</summary><RefundProofUpload job={r.job_id} id={r.id} method={r.method}/></details>}
 {r.status==="Approved" && <RefundUpdate id={r.id} kind="complete" method={r.method} proofs={files} accounts={accountChoices ?? []} originalAccount={job?.original_account_id}/>}

 </>}
 </Panel>;
 return modal ? <RefundCaseModal key={r.id} id={r.id} title={`${job?.code ?? r.job_id} · ${money(r.amount)}`} status={r.status} reason={r.reason} requested={denverDateTime(r.requested_at)} canReview={manage}>{details}</RefundCaseModal> : <div key={r.id}>{details}</div>;
        })}
 </div>;
 const active=(requests??[]).filter(r=>["Pending","In Review","Approved","Issued"].includes(r.status));
 const history=(requests??[]).filter(r=>r.status==="Completed");
 return <JobTabs defaultTab="active" tabs={[{id:"active",label:`Active (${active.length})`,content:<>{manage&&<Panel title="New refund"><RefundCreate jobs={jobId?jobs.filter(j=>j.id===jobId):jobs} jobId={jobId} requestKey={randomUUID()}/></Panel>}{render(active,true)}</>},{id:"history",label:`History (${history.length})`,content:render(history)}]}/>;
}
