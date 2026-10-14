export type Urgency = "green" | "orange" | "red";
export type UrgentItem = {kind:"refund"|"problem"|"lost";id:string;label:string;href:string;days:number;urgency:Urgency};
/** Overdue records never disappear after the last requested band. */
export function urgency(kind:UrgentItem["kind"],days:number):Urgency {
 if(kind==="lost")return "red";
 if(kind==="refund")return days<=2?"green":days<=4?"orange":"red";
 return days<=1?"green":days<=3?"orange":"red";
}
export function attentionBands(items:UrgentItem[]) {
 return (["red","orange","green"] as const).map(color=>({color,items:items.filter(item=>item.urgency===color)}));
}
import {TOOLTAG_TIMEZONE} from "./time";
function localDay(date:Date) {
 const parts=new Intl.DateTimeFormat("en-US",{timeZone:TOOLTAG_TIMEZONE,year:"numeric",month:"numeric",day:"numeric"}).formatToParts(date);
 const part=(key:string)=>Number(parts.find(p=>p.type===key)?.value);
 return Date.UTC(part("year"),part("month")-1,part("day"));
}
/** Inclusive day 1; Monday–Friday for response clocks, Denver dates across DST. */
export function queueDays(start:string,now:Date,business=false) {
 const from=localDay(new Date(start)),to=localDay(now);
 if(!Number.isFinite(from)||from>=to)return 1;
 if(!business)return Math.floor((to-from)/86400000)+1;
 let days=0;
 for(let day=from;day<=to;day+=86400000){const weekday=new Date(day).getUTCDay();if(weekday!==0&&weekday!==6)days++;}
 return Math.max(1,days);
}
export type AttentionRecord = {kind:UrgentItem["kind"];id:string;label:string;href:string;started_at:string};
export function classifyAttention(records:AttentionRecord[],now=new Date()):UrgentItem[] {
 return records.map(row=>{const days=queueDays(row.started_at,now,row.kind!=="lost");return {...row,days,urgency:urgency(row.kind,days)};});
}
export function categoryBadge(items:UrgentItem[],kind:UrgentItem["kind"]) {
 const rows=items.filter(row=>row.kind===kind);
 return {count:rows.length,color:(rows.some(row=>row.urgency==="red")?"red":rows.some(row=>row.urgency==="orange")?"orange":"green") as Urgency};
}
export function aggregateBands(items:UrgentItem[]) {
 const categories=[{kind:"problem",label:"Support",href:"/app/support"},{kind:"refund",label:"Refunds",href:"/app/refunds"},{kind:"lost",label:"Lost",href:"/app/lost"}] as const;
 return attentionBands(items).map(band=>({color:band.color,count:band.items.length,categories:categories.map(category=>({...category,count:band.items.filter(item=>item.kind===category.kind).length})).filter(category=>category.count>0)}));
}
