import {cents,decimal} from "./money";
import {queueDays, urgency} from "./urgent-attention";
import {TOOLTAG_TIMEZONE} from "./time";

export function refundAttention(confirmedAt: string | null, now = new Date()) {
 const days = confirmedAt ? queueDays(confirmedAt, now, true) : 0;
 return {days, color: urgency("refund", days)};
}
export function compareRefundUrgency(a:{confirmed_at:string|null;requested_at:string}, b:{confirmed_at:string|null;requested_at:string}, now = new Date()) {
 const left=refundAttention(a.confirmed_at,now),right=refundAttention(b.confirmed_at,now);
 const rank={red:0,orange:1,green:2};
 return rank[left.color]-rank[right.color] || right.days-left.days || Date.parse(a.requested_at)-Date.parse(b.requested_at);
}
function calendarDay(value:string) {
 const parts=new Intl.DateTimeFormat("en-US",{timeZone:TOOLTAG_TIMEZONE,year:"numeric",month:"numeric",day:"numeric"}).formatToParts(new Date(value));
 const part=(name:string)=>Number(parts.find(p=>p.type===name)?.value);
 return Date.UTC(part("year"),part("month")-1,part("day"))/86400000;
}
export function refundEligibility(eventAt:string|null,reportedAt:string) {
 if(!eventAt)return "Needs origin event/date review";
 if(!Number.isFinite(Date.parse(eventAt))||!Number.isFinite(Date.parse(reportedAt)))return "Needs origin event/date review";
 const days=calendarDay(reportedAt)-calendarDay(eventAt);
 return days>=0 && days<=14 && Date.parse(eventAt)<=Date.parse(reportedAt)
  ? "Within the 14-calendar-day reporting window"
  : "Outside the 14-calendar-day reporting window";
}
export function refundCompletionLabel(reason:string|null,channel?:string|null) {
 if(reason==="No response within 5 days")return "Auto-completed, no response";
 if(reason==="Customer confirmed")return "Client confirmed";
 if(reason==="Staff confirmed receipt")return `Client confirmed — recorded by staff${channel?` via ${channel}`:""}`;
 return reason || "Completed (legacy record)";
}

export function refundAmountRemaining(approved:string,processed:string) {
 return decimal(cents(approved)-cents(processed));
}

/** Issuance records the approved amount, never a silently changed amount. */
export function validateRefundIssueAmount(entered:string,approved:string,processed:string) {
 try {
  const expected=cents(approved)-cents(processed);
  return expected>0n && cents(entered)===expected ? null : "The amount must match the approved refund amount remaining to issue.";
 } catch {
  return "Enter a valid refund amount with at most two decimal places.";
 }
}
