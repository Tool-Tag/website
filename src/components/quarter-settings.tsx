"use client";
import {useState} from "react";
import {Form} from "./form";
import {fiscalQuarterStarts,fiscalStartMonth} from "@/lib/domain/presentation";
export function QuarterSettings({starts}:{starts:string[]}){
 const originalMonth=fiscalStartMonth(starts);
 const [mode,setMode]=useState(originalMonth===null?"custom":originalMonth===1?"calendar":"fiscal");
 const [month,setMonth]=useState(originalMonth??1);
 const dates=mode==="custom"?starts:fiscalQuarterStarts(mode==="calendar"?1:month);
 return <Form operation="sales-tax-quarter-settings" fields={[]} button="Save Reporting Year" back="/app/settings?tab=prices">
  <label>Reporting year<select aria-label="Reporting year" value={mode} onChange={event=>setMode(event.target.value)}><option value="calendar">Calendar year</option><option value="fiscal">Fiscal year</option>{originalMonth===null&&<option value="custom">Existing custom dates · preserved</option>}</select></label>
  {mode==="fiscal"&&<label>Fiscal start month<select aria-label="Fiscal start month" value={month} onChange={event=>setMonth(Number(event.target.value))}>{Array.from({length:12},(_,i)=><option key={i} value={i+1}>{new Intl.DateTimeFormat("en-US",{month:"long",timeZone:"UTC"}).format(new Date(Date.UTC(2001,i,1)))}</option>)}</select></label>}
  <p className="muted wide">{mode==="custom"?"Your custom dates remain unchanged. Choose Calendar or Fiscal only to replace them explicitly.":"Reporting periods only. Tax rates and recorded transactions stay unchanged."}</p>
  <div className="quarter-preview wide">{dates.map((date,index)=><span key={index}>Q{index+1} · {date}<input type="hidden" name={`q${index+1}_month`} value={date.slice(0,2)}/><input type="hidden" name={`q${index+1}_day`} value={date.slice(3)}/></span>)}</div>
 </Form>;
}
