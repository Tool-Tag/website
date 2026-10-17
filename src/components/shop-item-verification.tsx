"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {verifyShopItem} from "@/app/manual-audit-actions";
export function ShopItemVerification({items,checklist=false,evidenceAvailable=true}:{checklist?:boolean;evidenceAvailable?:boolean;items:{id:string;article:string;sequence:number;shop_received_at?:string|null}[]}){
 const [selected,setSelected]=useState<string[]>([]);
 const [saved,setSaved]=useState<string[]>([]);
 const [pending,start]=useTransition();const [error,setError]=useState("");const router=useRouter();
 if(checklist) return <section className="shop-receiving-checklist"><h3>Received at Shop</h3><p>Compare every physical item with the item list and receiving photos. Check each piece that has arrived. Production stays locked until all pieces are verified.</p>{!evidenceAvailable&&<p className="notice" role="status">No receiving evidence is registered for this job. Upload a receiving photo above before verifying the pieces.</p>}{items.map(item=>{
 const verified=Boolean(item.shop_received_at)||saved.includes(item.id);
 return <label className="checkbox" key={item.id}><input type="checkbox" checked={verified||selected.includes(item.id)} disabled={pending||verified||!evidenceAvailable} onChange={e=>setSelected(old=>e.target.checked?[...old,item.id]:old.filter(id=>id!==item.id))}/>{item.sequence}. {item.article}{verified?" · Verified at shop":""}</label>;
 })}<button type="button" disabled={pending||!items.length||!evidenceAvailable} onClick={()=>{
 setError("");
 const missing=items.filter(item=>!item.shop_received_at&&!saved.includes(item.id)&&!selected.includes(item.id));
 if(missing.length){setError(`Confirm every piece before saving. Missing verification: ${missing.map(item=>item.article).join(", ")}.`);return;}
 start(async()=>{
  for(const item of items.filter(item=>!item.shop_received_at&&!saved.includes(item.id))){
   const result=await verifyShopItem(item.id);
   if(result.error){setError(result.error);router.refresh();return;}
   setSaved(old=>[...old,item.id]);
  }
  router.refresh();
 });
 }}>{pending?"Saving…":"Verified"}</button>{error&&<p role="alert" className="notice error">{error}</p>}</section>;
 return <section className="panel"><h2>Received at Shop</h2><p>Compare every physical item with the item list and receiving photos before confirming. Production stays locked until all items are verified.</p>{items.map(item=><div className="shop-item-check" key={item.id}><span>{item.sequence}. {item.article}</span><button disabled={pending||Boolean(item.shop_received_at)} onClick={()=>start(async()=>{const result=await verifyShopItem(item.id);setError(result.error??"");if(!result.error)router.refresh();})}>{item.shop_received_at?"Verified at shop":"Confirm item received"}</button></div>)}{error&&<p role="alert" className="notice error">{error}</p>}</section>;
}
