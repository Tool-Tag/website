"use client";
import Link from "next/link";
import {usePathname} from "next/navigation";
export function FinanceTabs({includeGeneral=true}:{includeGeneral?:boolean}={}) {
 const path=usePathname();
 const tabs=[["","Overview"],["transactions","Transactions"],["sales","Sales"],["expenses","Expenses"],["refunds","Refunds"],["sms","SMS Costs"],["reports","Monthly Closes"],["review","Review"],["about","About"]];
 return <nav className="main-tab-list" aria-label="Finance sections">{tabs.filter(([key])=>includeGeneral||key==="refunds").map(([key,label])=>{
 const href=`/app/finance${key?"/"+key:""}`,active=key?path===href||path.startsWith(href+"/"):path===href;
 return <Link key={key} className={`main-tab ${active?"active":""}`} href={href} aria-current={active?"page":undefined}>{label}</Link>;
 })}</nav>;
}
