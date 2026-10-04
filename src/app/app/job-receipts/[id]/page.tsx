import Link from "next/link";
import { rows } from "@/lib/domain/context";
import { receiptText,type ReceiptSnapshot } from "@/lib/integrations/receipt-mail";
import { PrintRecord } from "@/components/print-record";
export default async function Receipt({params}:{params:Promise<{id:string}>}) {
 const {id}=await params;const r=(await rows("job_receipts",{id}))[0];if(!r) return <p>Recibo no encontrado.</p>;
 return <><Link href={`/app/jobs/${r.job_id}`}>← Volver al trabajo</Link><h1>Resumen de pagos</h1><PrintRecord/><pre style={{whiteSpace:"pre-wrap",overflowWrap:"anywhere"}}>{receiptText(r.snapshot as ReceiptSnapshot)}</pre><p>Drive: {r.storage_status}</p><p className="muted">Verificación: {r.snapshot_sha256}</p></>;
}
