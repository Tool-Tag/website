import { TOOLTAG_TIMEZONE } from "./time";
export function driverDates(value?:string, now=new Date()) {
 const today=now.toLocaleDateString("en-CA",{timeZone:TOOLTAG_TIMEZONE});
 const valid=value && /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value+"T12:00:00Z")) && new Date(value+"T12:00:00Z").toISOString().slice(0,10)===value;
 const selected=valid?value:today;
 const next=(weekday:number)=>{const d=new Date(selected+"T12:00:00Z"); d.setUTCDate(d.getUTCDate()+(weekday-d.getUTCDay()+7)%7);return d.toISOString().slice(0,10);};
 return {selected,pickup:next(6),return:next(0)};
}
export function routeDateLabel(date:string){return new Date(date+"T12:00:00Z").toLocaleDateString("en-US",{timeZone:TOOLTAG_TIMEZONE,weekday:"long",month:"short",day:"numeric",year:"numeric"});}
