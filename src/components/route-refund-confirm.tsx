"use client";
import {useRouter} from "next/navigation";
import {useState,useTransition} from "react";
import {confirmRouteRefund} from "@/app/route-exception-actions";
export function RouteRefundConfirm({id}:{id:string}){const router=useRouter();const [reference,setReference]=useState('');const [pending,start]=useTransition();const [error,setError]=useState('');return <div><label>Actual refund reference / proof<input value={reference} onChange={e=>setReference(e.target.value)} /></label><button disabled={pending||!reference.trim()} onClick={()=>{if(window.confirm('Confirm you actually issued this refund to the original payment method?'))start(async()=>{const result=await confirmRouteRefund(id,reference);setError(result.error??'');if(!result.error)router.refresh();});}}>Confirm refund actually issued</button>{error&&<p role="alert">{error}</p>}</div>;}
