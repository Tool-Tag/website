import Link from "next/link";
import { requirePermission } from "@/lib/domain/context";
import { Panel, Table, Empty } from "@/components/ui";
import { money } from "@/lib/domain/money";
export async function SmsCosts({ jobId, quoteId }: {
    jobId?: string;
    quoteId?: string;
}) {
    const { db, unit } = await requirePermission("payments.view");
    let query = db.from("sms_cost_totals").select("*").eq("unit_id", unit).order("updated_at", { ascending: false });
    if (jobId)
        query = query.eq("job_id", jobId);
    if (quoteId) {
        const { data, error } = await db.from("quotes").select("flow_id").eq("unit_id", unit).eq("id", quoteId).single();
        if (error)
            throw new Error(error.message);
        query = query.eq("flow_id", data.flow_id);
    }
    const { data, error } = await query;
    if (error)
        throw new Error(error.message);
    return <SmsCostTable data={data??[]}/>;
}
export type SmsCostRow={id:string;job_id:string|null;quote_id:string|null;job_code:string|null;quote_code:string;sms_count:number;delivered_count:number;delivery_failed_count:number;delivery_unknown_count:number;acceptance_unknown_count:number;exact_cost:number|string;posted_amount:number|string;posting_error:string|null;closed_at:string|null};
export function SmsCostTable({data}:{data:SmsCostRow[]}){
    return <Panel title="SMS costs">{!data?.length ? <Empty>No costed SMS sends yet.</Empty> : <Table headers={["Quote / Job", "AWS accepted", "Delivered / failed / unknown", "Unconfirmed acceptance", "Exact cost", "Posted expense", "State"]}>{data.map(a => <tr key={a.id}><td>{a.job_id ? <Link href={`/app/jobs/${a.job_id}`}>{a.job_code}</Link> : a.quote_id ? <Link href={`/app/quotes/${a.quote_id}`}>{a.quote_code}</Link> : a.quote_code}<br /><small>Quote origin: {a.quote_code}</small></td><td>{a.sms_count}</td><td>{a.delivered_count} / {a.delivery_failed_count} / {a.delivery_unknown_count}</td><td>{a.acceptance_unknown_count}</td><td>${Number(a.exact_cost).toFixed(8)}</td><td>{money(a.posted_amount)}</td><td>{a.posting_error ?? (a.acceptance_unknown_count > 0 ? "Awaiting acceptance reconciliation" : a.closed_at ? "Closed" : "Accumulating")}</td></tr>)}</Table>}<p className="muted">Costs count AWS-accepted sends, including delivery failures. AWS acceptance is not delivery confirmation. Carrier outcomes remain unknown until observed; unconfirmed API outcomes await reconciliation. CloudWatch integration is deferred.</p></Panel>;
}
