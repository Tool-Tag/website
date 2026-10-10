"use client";
import {useEffect, useState} from "react";
import {useRouter} from "next/navigation";
import {routeAvailability, scheduleRoute} from "@/app/route-actions";
import {TOOLTAG_TIMEZONE} from "@/lib/domain/time";
type Availability = {day:string; slots:{eta:string;label:string}[]; moved:boolean};
export function RouteCalendar({job,leg,token}:{job:string;leg:"Pickup"|"Return";token?:string}) {
 const router=useRouter();
 const today=new Intl.DateTimeFormat("en-CA",{timeZone:TOOLTAG_TIMEZONE,year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
 const [offset,setOffset]=useState(0), [available,setAvailable]=useState<Availability|null>(null),[eta,setEta]=useState(""),[pending,setPending]=useState(false),[error,setError]=useState(""),[ok,setOk]=useState(false);
 const [dayAvailability,setDayAvailability]=useState<Record<string,boolean>>({});
 useEffect(()=>{
  let cancelled=false;
  const candidates=Array.from({length:28},(_,i)=>{const date=new Date(today+"T12:00:00Z");date.setUTCDate(date.getUTCDate()+offset+i);return date;}).filter(date=>date.getUTCDay()===(leg === "Pickup" ? 6 : 0));
  Promise.all(candidates.map(async date=>{
   const day=date.toISOString().slice(0,10);
   try {const result=await routeAvailability(job,leg,day,token);return [day,!result.error && result.data?.day===day && result.data?.slots?.length>0] as const;}
   catch {return [day,false] as const;}
  })).then(entries=>{if(!cancelled)setDayAvailability(Object.fromEntries(entries));});
  return ()=>{cancelled=true;};
 },[job,leg,offset,today,token]);
 const days=Array.from({length:28},(_,i)=>{const d=new Date(today+"T12:00:00Z");d.setUTCDate(d.getUTCDate()+offset+i);return d;});
 async function choose(day:string) {
  setPending(true);setError("");setOk(false);setAvailable(null);setEta("");
  try {const result=await routeAvailability(job,leg,day,token);if(result.error)setError(result.error);else {setAvailable(result.data);setEta(result.data.slots[0]?.eta || "");}} catch {setError("Could not load route availability. Please retry.");} finally{setPending(false);}
 }
 async function save(){if(!available)return;setPending(true);setError("");try{const result=await scheduleRoute(job,leg,available.day,eta,token);if(result.error){setError(result.error);setAvailable(null);}else{setOk(true);router.refresh();}}catch{setError("Could not schedule. Please retry.");}finally{setPending(false);}}
 return <section className="stack"><p>{leg === "Pickup" ? "Saturdays · 8:00 AM–12:00 PM" : "Sundays · 2:00 PM–6:00 PM"} (Denver)</p>
 <div className="actions"><button type="button" disabled={pending || offset===0} onClick={()=>setOffset(Math.max(0,offset-28))}>Previous</button><button type="button" disabled={pending} onClick={()=>setOffset(offset+28)}>Next dates</button></div>
 <div role="group" aria-label={`${leg} calendar`} style={{display:"grid",gridTemplateColumns:"repeat(7,minmax(0,1fr))",gap:4}}>{days.map(d=>{const day=d.toISOString().slice(0,10);return <button key={day} type="button" disabled={pending || d.getUTCDay() !== (leg === "Pickup" ? 6 : 0) || !dayAvailability[day]} aria-pressed={available?.day===day} onClick={()=>choose(day)}>{d.toLocaleDateString("en-US",{timeZone:"UTC",month:"short",day:"numeric",weekday:"short"})}</button>;})}</div>
 {available && <>{available.moved && <p className="notice">That date is unavailable. The next available date is {available.day}. Saving will notify the customer.</p>}<label>Initial ETA<select value={eta} onChange={e=>setEta(e.target.value)} disabled={pending}>{available.slots.map(s=><option key={s.eta} value={s.eta}>{s.label}</option>)}</select></label><button type="button" disabled={pending || !eta} onClick={save}>{pending ? "Saving…" : `Schedule ${leg}`}</button></>}
 {error && <p className="notice error" role="alert">{error}</p>}{ok && <p className="notice success">Scheduled. The customer has been notified.</p>}
 </section>;
}
