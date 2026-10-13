import Link from "next/link";
import { Panel } from "@/components/ui";
export function SmsExpenseTrace({ snapshot: s }: {
    snapshot: {
        job_id?: string;
        job_code?: string;
        quote_id?: string;
        quote_code: string;
        sms_count: number;
        exact_cost: number;
        posted_delta: number;
        rates?: {
            unit_cost: number;
            sms_count: number;
        }[];
    };
}) { return <Panel title="SMS expense trace"><p>{s.job_id ? <Link href={`/app/jobs/${s.job_id}`}>{s.job_code}</Link> : s.quote_code} · Quote {s.quote_id ? <Link href={`/app/quotes/${s.quote_id}`}>{s.quote_code}</Link> : s.quote_code}</p><p>{s.sms_count} AWS accepted · exact cumulative cost ${Number(s.exact_cost).toFixed(8)} · this posting ${Number(s.posted_delta).toFixed(2)}</p>{s.rates?.map(r => <p key={String(r.unit_cost)}>{r.sms_count} × ${Number(r.unit_cost).toFixed(8)}</p>)}</Panel>; }
