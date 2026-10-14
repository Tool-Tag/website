"use client";
import {useEffect} from "react";
/** Also recheck when a suspended tab wakes up; activity never extends the deadline. */
export function SessionTimeout({expiresAt,serverNow}: {expiresAt:string;serverNow:string}) {
 useEffect(()=>{
  const end=Date.now()+(Date.parse(expiresAt)-Date.parse(serverNow));
  const check=()=>{if(!Number.isFinite(end)||Date.now()>=end)window.location.replace("/auth/session-expired");};
  const timer=setTimeout(check,Math.max(0,end-Date.now()));
  const interval=setInterval(check,15000);
  document.addEventListener("visibilitychange",check);window.addEventListener("focus",check);
  return()=>{clearTimeout(timer);clearInterval(interval);document.removeEventListener("visibilitychange",check);window.removeEventListener("focus",check);};
 },[expiresAt,serverNow]);
 return null;
}
