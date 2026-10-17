"use client";
import {useEffect,useTransition} from "react";
import {useRouter} from "next/navigation";
import {salesTaxQuarter} from "@/lib/domain/sales-tax-summary";

/** Refresh the reporting period if the Overview stays open over a boundary. */
export function FinanceQuarterRollover({starts,currentStart}:{starts:string[];currentStart:string}) {
  const router=useRouter(),[,startTransition]=useTransition(),key=starts.join("|");
  useEffect(()=>{
    let refreshing=false;
    const check=()=>{
      if(!refreshing&&document.visibilityState==="visible"&&salesTaxQuarter(new Date(),key.split("|")).start!==currentStart){refreshing=true;startTransition(()=>router.refresh());}
    };
    check();
    const timer=window.setInterval(check,30000);
    document.addEventListener("visibilitychange",check);
    return()=>{window.clearInterval(timer);document.removeEventListener("visibilitychange",check);};
  },[key,currentStart,router]);
  return null;
}
