"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import type {RouteChecklist} from "./route-item-verification";
import {getRouteChecklist} from "@/app/manual-audit-actions";
import {verifyFailedDelivery,markFailedDeliveryLost} from "@/app/failed-delivery-actions";
import {useAccess} from "./permission-provider";
import {can} from "@/lib/auth/permissions";
export type FailedVerification={stop:string;route:string;job:string;name:string;status:string};
type Item={id:string;article:string;sequence:number;checked:boolean};
export function FailedDeliveryVerification({rows}:{rows:FailedVerification[]}){
 const router=useRouter();const access=useAccess();const [row,setRow]=useState<FailedVerification|null>(null);const [items,setItems]=useState<Item[]>([]);const [selected,setSelected]=useState<string[]>([]);const [missing,setMissing]=useState<Item[]>([]);const [loss,setLoss]=useState(false);const [notes,setNotes]=useState("");const [error,setError]=useState("");const [pending,start]=useTransition();
 const open=(r:FailedVerification)=>start(async()=>{setError("");const result=await getRouteChecklist(r.route,"Returned");if(result.error){setError(result.error);return;}const list=(result.data as RouteChecklist[]).find(s=>s.stop===r.stop)?.items??[];setItems(list);setSelected(list.filter(i=>i.checked).map(i=>i.id));setRow(r);setMissing([]);setLoss(false);setNotes("");});
 const verify=()=>{const unchecked=items.filter(i=>!selected.includes(i.id));if(unchecked.length){setMissing(unchecked);return;}if(!row)return;start(async()=>{const r=await verifyFailedDelivery(row.stop,selected);if(r.error)setError(r.error);else{setRow(null);router.refresh();}});};
 return <section className="panel"><h2>Failed delivery verification</h2><p>Verify items returned to the shop. Failed jobs are removed from the block, but their shop-arrival check remains linked to its closure.</p>{!rows.length&&<p>No failed deliveries to verify.</p>}<div className="delivery-block-grid">{rows.map(r=><button className="panel delivery-block-card" key={r.stop} disabled={r.status!=="Pending"||pending||!can(access,"pr.returns")} onClick={()=>open(r)}><strong>{r.job} · {r.name}</strong><span>{r.status==="Verified"?"Verified · shop arrival confirmed":"Awaiting shop verification"}</span></button>)}</div>{error&&!row&&<p role="alert">{error}</p>}
 {row&&<div className="delivery-ack-backdrop"><section className="delivery-ack-panel" role="dialog" aria-modal="true" aria-label="Verify returned items"><h2>{row.job} · Shop arrival</h2>{!missing.length&&!loss&&<>{items.map(i=><label className="checkbox" key={i.id}><input type="checkbox" checked={selected.includes(i.id)} disabled={pending||i.checked} onChange={e=>setSelected(old=>e.target.checked?[...old,i.id]:old.filter(id=>id!==i.id))}/>{i.sequence}. {i.article}</label>)}<button disabled={pending||!items.length} onClick={verify}>Verified</button></>}
 {missing.length>0&&!loss&&<><h3>Missing verification</h3><ul>{missing.map(i=><li key={i.id}>Missing verification: {i.article} from job {row.job}.</li>)}</ul><div className="actions"><button className="secondary" onClick={()=>setMissing([])}>Go back</button><button onClick={()=>setLoss(true)}>Mark as lost</button></div></>}
 {loss&&<><label>Explain what happened<textarea value={notes} onChange={e=>setNotes(e.target.value)} required disabled={pending}/></label><div className="actions"><button className="secondary" disabled={pending} onClick={()=>setLoss(false)}>Go back</button><button disabled={pending||!notes.trim()} onClick={()=>start(async()=>{const result=await markFailedDeliveryLost(row.stop,selected,notes);if(result.error)setError(result.error);else{setRow(null);router.refresh();}})}>Confirm lost report</button></div></>}
 <button className="secondary" disabled={pending} onClick={()=>setRow(null)}>Close</button>{error&&<p role="alert">{error}</p>}</section></div>}
 </section>;
}
