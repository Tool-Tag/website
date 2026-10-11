"use client";
import {useState,useTransition} from "react";
import {useRouter} from "next/navigation";
import {verifyShopItem} from "@/app/manual-audit-actions";
export function ShopItemVerification({items}:{items:{id:string;article:string;sequence:number;shop_received_at?:string|null}[]}){
 const [pending,start]=useTransition();const [error,setError]=useState("");const router=useRouter();
 return <section className="panel"><h2>Received at Shop</h2><p>Compare every physical item with the item list and receiving photos before confirming. Production stays locked until all items are verified.</p>{items.map(item=><div className="shop-item-check" key={item.id}><span>{item.sequence}. {item.article}</span><button disabled={pending||Boolean(item.shop_received_at)} onClick={()=>start(async()=>{const result=await verifyShopItem(item.id);setError(result.error??"");if(!result.error)router.refresh();})}>{item.shop_received_at?"Verified at shop":"Confirm item received"}</button></div>)}{error&&<p role="alert" className="notice error">{error}</p>}</section>;
}
