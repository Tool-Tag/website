"use client";
import {useActionModal} from "./action-modal";
import { useActionState, useState, useEffect } from "react";
import { refundAction, type RefundState } from "@/app/refund-actions";
export type RefundJob = {
    id: string;
    code: string;
    quote_code: string;
    customer_name?: string;
    original_method: string | null;
    original_account_id?: string;
    available: number;
    issue_events?: Record<string, string | null>;
};
const methods = ["Zelle", "Venmo", "Card", "Bank Transfer", "Check"];
const reasons = ["Customer cancellation", "ToolTag error", "Driver-down $5", "Driver-down $10", "Damage", "Other"];
function Feedback({ state, pending, label }: {
    state: RefundState;
    pending: boolean;
    label: string;
}) { return <><button disabled={pending}>{pending ? "Saving…" : label}</button>{state.error && <p role="alert" className="notice error">{state.error}</p>}{state.ok && <p role="status" className="notice success">Saved.</p>}</>; }
function RefundDate({ name, label, fixedDate }: {
    name: string;
    label: string;
    fixedDate?: string | null;
}) {
    const [date, setDate] = useState("");
    const stored = fixedDate ? new Date(fixedDate) : null;
    const display = stored ? new Date(stored.getTime() - stored.getTimezoneOffset() * 60000).toISOString().slice(0, 16) : date;
    return <label>{label}<input type="datetime-local" required value={display} readOnly={Boolean(stored)} onChange={e => setDate(e.target.value)}/><input type="hidden" name={name} value={stored?.toISOString() ?? (date ? new Date(date).toISOString() : "")}/>{stored && <small>Recorded event; its date is fixed.</small>}</label>;
}
export function RefundCreate({ jobs, jobId, requestKey }: {
    jobs: RefundJob[];
    jobId?: string;
    requestKey: string;
}) {
    const closeModal=useActionModal();
    const [selected, setSelected] = useState(jobId ?? "");
    const job = jobs.find(j => j.id === selected);
    const [event, setEvent] = useState("Pickup");
    const [amount, setAmount] = useState("5.00");
    const [state, action, pending] = useActionState(refundAction.bind(null, "create", requestKey), {});
    useEffect(()=>{if(state.ok)closeModal?.();},[state,closeModal]);
    return <form action={action} className="formgrid">
 <label>Job<select name="job_id" required value={selected} onChange={e => setSelected(e.target.value)}><option value="">Select Job…</option>{jobs.map(j => <option key={j.id} value={j.id}>{j.code} · {j.quote_code}</option>)}</select></label>
 <label>Amount (USD)<div className="actions"><button type="button" className="secondary" onClick={() => setAmount("5.00")}>$5</button><button type="button" className="secondary" onClick={() => setAmount("10.00")}>$10</button></div><input name="amount" type="number" step="0.01" min="0.01" required value={amount} onChange={e => setAmount(e.target.value)}/><small>Available, after pending refunds: ${Number(job?.available ?? 0).toFixed(2)}</small></label>
 <label>Reason<select name="reason" required>{reasons.map(r => <option key={r}>{r}</option>)}</select></label>
 <label>Refund method<select key={selected} name="method" defaultValue={methods.includes(job?.original_method ?? "") ? job!.original_method! : ""}><option value="">Choose before processing…</option>{methods.map(m => <option key={m}>{m}</option>)}</select><small>Original: {job?.original_method ?? "No confirmed payment"}. Cash refunds are not allowed.</small></label>
 <label>Issue event<select name="issue_event" required value={event} onChange={e => setEvent(e.target.value)}>{["Pickup", "Return", "Delivery", "Completion notice"].map(x => <option key={x} value={x}>{x==="Return"?"Delivery attempt":x}</option>)}</select></label>
 <RefundDate name="issue_event_at" label="Event date/time (your local time)" fixedDate={job?.issue_events?.[event]}/>
 <RefundDate name="reported_at" label="Issue reported date/time (your local time)"/>
 <label className="wide">Notes<textarea name="notes" maxLength={5000}/></label>
 <p className="muted wide">Report within 14 calendar days of the selected event. Staff confirms eligibility; processing is due 5–7 business days later (Monday–Friday).</p>
 <Feedback state={state} pending={pending} label="Create pending refund"/>
 </form>;
}
export function RefundUpdate({ id, kind, amount, method, proofs, review, accounts, originalAccount }: {
    id: string;
    kind: "review" | "approve" | "confirm" | "complete" | "cancel" | "reject" | "acknowledge" | "note";
    amount?: string;
    method?: string | null;
    proofs?: {
        id: string;
        file_name: string;
        refund_method?:string|null;
    }[];
    review?: boolean;
    accounts?: {
        id: string;
        name: string;
    }[];
    originalAccount?: string;
}) {
    const [state, action, pending] = useActionState(refundAction.bind(null, kind, id), {});
    return <form action={action} className="formgrid">
 {kind === "confirm" && review && <label><input type="checkbox" name="reviewed" required/> I reviewed payment eligibility and prior provider activity; no refund will be duplicated.</label>}
 {kind === "complete" && <><p className="notice wide">Manual processing only. Issue the money outside ToolTag first, then record its reference and proof here. This button does not transfer funds.</p><label>Amount (USD)<input name="amount" type="number" min="0.01" step="0.01" required defaultValue={amount}/><small>Approved amount to issue: ${amount}. The entered amount must match this approval.</small></label><label>Method<select name="method" defaultValue={method ?? ""} required><option value="">Electronic method or Check…</option>{methods.map(m => <option key={m}>{m}</option>)}</select></label><label>Account that funded the refund<select name="account_id" defaultValue={originalAccount ?? ""} required><option value="">Select account…</option>{accounts?.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}</select></label><label>Reference<input name="reference" required maxLength={200}/></label><label>Stored screenshot (must match the selected method)<select name="proof_id" required><option value="">Select proof…</option>{proofs?.map(p => <option key={p.id} value={p.id}>{p.file_name}{p.refund_method?` · ${p.refund_method}`:""}</option>)}</select></label><label className="wide">Processing notes<textarea name="notes" maxLength={2000}/></label></>}
 {kind === "reject" && <label className="wide">Rejection reason<textarea name="reason" required maxLength={2000}/></label>}
 {kind === "acknowledge" && <><p className="muted wide">Record that the customer confirmed receipt by phone or email. This does not issue another refund.</p><label>Confirmation channel<select name="channel" required><option value="">Select…</option><option>Phone</option><option>Email</option></select></label><label className="wide">Customer confirmation notes<textarea name="notes" required maxLength={2000}/></label></>}
 {kind === "note" && <label className="wide">Add an internal note<textarea name="notes" required maxLength={2000}/></label>}
 {kind === "cancel" && <label>Cancellation notes<textarea name="notes" required maxLength={2000}/></label>}
 <Feedback state={state} pending={pending} label={kind === "reject"?"Reject refund":kind === "acknowledge"?"Mark Completed — customer confirmed":kind === "note"?"Save note":kind === "review"?"Start review":kind === "approve"?"Approve refund":kind === "confirm" ? "Confirm eligibility" : kind === "complete" ? "Record issued refund" : "Cancel refund"}/>
 </form>;
}
