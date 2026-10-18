"use client";
import {useState} from "react";
import {displayLabel} from "@/lib/domain/ui-labels";
import {denverDateTime} from "@/lib/domain/time";
import {jobTimelineProgress} from "@/lib/domain/customer-route-tracking";
export function StatusTimeline({steps,current,updated,finished,total}:{steps:string[];current:string;updated:string;finished:number;total:number}){
 const progress=jobTimelineProgress(steps,current),[showDone,setShowDone]=useState(true),[showUpcoming,setShowUpcoming]=useState(false);
 const done=progress.done.filter(step=>step!=="Completed"),upcoming=progress.upcoming.filter(step=>step!=="Completed");
 const node=(step:string,complete=false,active=false)=><div key={step} className={`status-step${complete?" complete":""}${active?" active":""}`}><span className="status-dot" aria-hidden="true">{complete?"✓":active?"●":"○"}</span><strong title={displayLabel(step)}>{active?"Current · ":""}{displayLabel(step)}{active&&current==="Engraving"&&total>0?` · ${finished}/${total} pieces`:""}</strong></div>;
 return <><div className="job-timeline-scroll" tabIndex={0} aria-label="Job progress"><div className="job-timeline-line">{showDone&&done.map(step=>node(step,true))}{current!=="Completed"&&node(current,false,true)}{upcoming.length>0&&<div className="status-step upcoming-group"><button type="button" className="timeline-upcoming-pill" aria-expanded={showUpcoming} onClick={()=>setShowUpcoming(!showUpcoming)}>Upcoming… ({upcoming.length})</button></div>}{showUpcoming&&upcoming.map(step=>node(step))}{node("Completed",current==="Completed",current==="Completed")}</div></div><button type="button" className="timeline-completed-toggle" aria-expanded={showDone} onClick={()=>setShowDone(!showDone)}>✓ Completed… ({done.length})</button><label className="tracking-progress">Job progress: {progress.percentage}%<progress max={100} value={progress.percentage} style={{width:"100%"}} /></label><p className="muted status-updated tracking-progress">Last updated: {denverDateTime(updated)}</p></>;
}
