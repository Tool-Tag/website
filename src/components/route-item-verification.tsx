"use client";
import {useAccess} from "./permission-provider";
import {canAny} from "@/lib/auth/permissions";
import {useRouter} from "next/navigation";
import {useState,useTransition} from "react";
import {getRouteChecklist,verifyRouteItems} from "@/app/manual-audit-actions";
export type RouteChecklist={stop:string;name:string;job:string;items:{id:string;article:string;sequence:number;checked:boolean}[]};
export function RouteItemVerification({route,kind,onComplete}:{route:string;kind:"Loaded"|"Returned";onComplete?:()=>void}){
 const access=useAccess();
 const router=useRouter();
 const [open,setOpen]=useState(false);const [rows,setRows]=useState<RouteChecklist[]>([]);const [selected,setSelected]=useState<string[]>([]);const [error,setError]=useState("");const [pending,start]=useTransition();
 const load=()=>start(async()=>{const result=await getRouteChecklist(route,kind);if(result.error)setError(result.error);else{setRows(result.data);setOpen(true);}});
 const complete=rows.length>0&&rows.every(row=>row.items.length>0&&row.items.every(item=>item.checked));
 if(!canAny(access,kind==="Returned"?["pr.returns"]:["pr.returns","pr.routes.live","driver.routes"]))return null;
 return <><button className="secondary" onClick={load} disabled={pending}>{kind==="Loaded"?"Leaving the shop · verify items":"Verify undelivered items returned to shop"}</button>{open&&<div className="delivery-ack-backdrop"><section role="dialog" aria-modal="true" aria-label="Verify route items" className="delivery-ack-panel"><h2>{kind==="Loaded"?"Verify items before departure":"Shop return verification"}</h2><p>Compare each physical item with the list and evidence.</p>{rows.map(row=><details key={row.stop} className={row.items.every(i=>i.checked)?"notice success":"notice route-check-pending"}><summary>{row.name} · {row.job} · {row.items.every(i=>i.checked)?"Verified":"Needs verification"}</summary>{row.items.map(item=><label className="checkbox" key={item.id}><input type="checkbox" checked={item.checked||selected.includes(item.id)} disabled={item.checked||pending} onChange={event=>setSelected(value=>event.target.checked?[...value,item.id]:value.filter(id=>id!==item.id))}/>{item.sequence}. {item.article}</label>)}<button disabled={pending||!row.items.every(i=>i.checked||selected.includes(i.id))} onClick={()=>start(async()=>{const result=await verifyRouteItems(row.stop,kind,row.items.map(i=>i.id));if(result.error)setError(result.error);else {const next=await getRouteChecklist(route,kind);if(next.error)setError(next.error);else setRows(next.data);}})}>Confirm items</button></details>)}{complete&&<button onClick={()=>{setOpen(false);onComplete?.();router.refresh();}}>{kind==="Loaded"?"Start Route":"Verification complete"}</button>}<button className="secondary modal-close" onClick={()=>setOpen(false)} aria-label="Close dialog">×</button>{error&&<p role="alert" className="notice error">{error}</p>}</section></div>}</>;
}
