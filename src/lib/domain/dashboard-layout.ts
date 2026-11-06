import {TOOLTAG_TIMEZONE} from './time';
/** Date-only reporting range in the business timezone; not a scheduling cutoff. */
export function dashboardWeekRange(now=new Date()){
 const today=now.toLocaleDateString('en-CA',{timeZone:TOOLTAG_TIMEZONE});
 const monday=new Date(today+'T12:00:00Z');monday.setUTCDate(monday.getUTCDate()-(monday.getUTCDay()+6)%7);
 return {today,monday:monday.toISOString().slice(0,10)};
}
