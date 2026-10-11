"use client";
import {useEffect,useTransition} from "react";
import {useRouter} from "next/navigation";
import {createBrowserClient} from "@supabase/ssr";
export function StatusRefresh({channels=[]}:{channels?:string[]}) {
 const router=useRouter();const [,startTransition]=useTransition();const key=channels.join("|");
 useEffect(()=>{
  let debounce:number|undefined;const refresh=()=>{if(document.visibilityState!=="visible")return;window.clearTimeout(debounce);debounce=window.setTimeout(()=>startTransition(()=>router.refresh()),150);};
  const timer=window.setInterval(refresh,20000);document.addEventListener("visibilitychange",refresh);
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;const publishable=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const db=url&&publishable?createBrowserClient(url,publishable):null;
  const subscriptions=key&&db?key.split("|").map(topic=>db.channel(topic).on("broadcast",{event:"refresh"},refresh).subscribe()):[];
  return()=>{window.clearInterval(timer);window.clearTimeout(debounce);document.removeEventListener("visibilitychange",refresh);subscriptions.forEach(channel=>{void db?.removeChannel(channel);});};
 },[router,key]);return null;
}
