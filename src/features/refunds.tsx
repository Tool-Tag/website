import Link from "next/link";
import { randomUUID } from "node:crypto";
import { requirePermission } from "@/lib/domain/context";
import { can } from "@/lib/auth/permissions";
import { Panel, Empty, Badge } from "@/components/ui";
import { RefundCreate, RefundUpdate, type RefundJob } from "@/components/refund-forms";
import { EvidenceUpload } from "@/components/evidence-upload";
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
    const manage = can(access, "payments.refund");
    const ids = (requests ?? []).map(r => r.id);
    const { data: documents, error: docError } = ids.length ? await db.from("documents").select("id,file_name,refund_request_id,storage_status,type").eq("unit_id", unit).in("refund_request_id", ids) : { data: [], error: null };
    if (docError)
        throw new Error(docError.message);
    return <div className="stack">
 {manage && <Panel title="New refund"><RefundCreate jobs={jobId ? jobs.filter(j => j.id === jobId) : jobs} jobId={jobId} requestKey={randomUUID()}/></Panel>}
 {(requests ?? []).length === 0 && <Empty>No refunds for this selection.</Empty>}
 {(requests ?? []).map(r => {
            const job = jobs.find(j => j.id === r.job_id);
            const files = (documents ?? []).filter(d => d.refund_request_id === r.id && d.storage_status === "stored");
            return <Panel key={r.id} title={`${job?.code ?? r.job_id} · ${money(r.amount)}`}>
 <Badge>{r.status}</Badge><p>{r.reason} · {r.source_kind} · Issued: {money(r.processed_amount)}</p><p>Original method: {r.original_method ?? "Unconfirmed"} · Refund method: {r.method ?? "Selection required"}</p>
 <p>Requested: {denverDateTime(r.requested_at)} · Reported: {denverDateTime(r.reported_at)}</p>
 {r.issue_event && <p>Issue event: {r.issue_event} · {denverDateTime(r.issue_event_at)}</p>}
 <p>Accounting period: {String(r.accounting_period).slice(0, 7)}</p>
 {r.confirmed_at && <p>Eligibility confirmed: {denverDateTime(r.confirmed_at)} · Process {r.process_not_before}–{r.process_due} (business days)</p>}
 {r.processed_at && <p>Processed: {denverDateTime(r.processed_at)} · By: {r.confirmation_snapshot?.processor_name ?? r.processed_by} · Reference: {r.reference}</p>}
 {r.notes && <p>{r.notes}</p>}
 {files.map(f => <p key={f.id}><Link href={`/app/documents/${f.id}/download`} target="_blank">Proof: {f.file_name}</Link></p>)}
 {r.confirmation_snapshot && <p className="notice success">Confirmation: {money(r.confirmation_snapshot.amount)} · {r.confirmation_snapshot.method} · {denverDateTime(r.confirmation_snapshot.processed_at)} · {r.confirmation_snapshot.job_code} / {r.confirmation_snapshot.quote_code} · Reference {r.confirmation_snapshot.reference}</p>}
 {manage && r.status === "Pending" && <>
 {!r.confirmed_at && <RefundUpdate id={r.id} kind="confirm" review={r.requires_review}/>}
 <details><summary>Upload refund proof</summary><EvidenceUpload config={{ jobId: r.job_id, refundRequestId: r.id, type: "Refund Review Evidence", defaultVisibility: "internal", back: "/app/finance/refunds" }}/></details>
 {r.confirmed_at && <RefundUpdate id={r.id} kind="complete" method={r.method} proofs={files} accounts={accountChoices ?? []} originalAccount={job?.original_account_id}/>}
 <details><summary>Cancel refund request</summary><RefundUpdate id={r.id} kind="cancel"/></details>
 </>}
 </Panel>;
        })}
 </div>;
}
