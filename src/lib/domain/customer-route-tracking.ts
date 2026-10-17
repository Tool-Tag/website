export type CustomerRouteStop = {position:number;status:string;is_customer:boolean};
export type CustomerRoute = {leg:"Pickup"|"Return";date:string;stops:CustomerRouteStop[];total:number;resolved:number;remaining_to_customer:number;own_status:string;scheduled_eta:string|null;estimated_eta:string|null;estimate_updated_at:string|null;updated_at:string|null;closed:boolean;paused:boolean;window_start:string;window_end:string};
export const resolvedStop=(status:string)=>["Completed","Failed","Cancelled"].includes(status);
export function routeProgress(stops:CustomerRouteStop[]){
 const done=stops.filter(s=>resolvedStop(s.status));
 const current=stops.filter(s=>["En Route","Arrived"].includes(s.status));
 const upcoming=stops.filter(s=>!resolvedStop(s.status)&&!["En Route","Arrived"].includes(s.status));
 return {done,current,upcoming,percentage:stops.length?Math.round(done.length/stops.length*100):0};
}

export function jobTimelineProgress(steps:string[],current:string){
 const operational=["Pending Delivery","Shop Pickup"].includes(current)?"Delivery In Progress":current;
 const index=Math.max(0,steps.indexOf(operational));const completed=current==="Completed"?steps.length:index;
 return {done:steps.slice(0,completed),upcoming:current==="Completed"?[]:steps.slice(index+1),percentage:steps.length?Math.round(completed/steps.length*100):0};
}

export const stopStatusLabel:Record<string,string>={Requested:"Pending reservation",Scheduled:"Scheduled","En Route":"En route",Arrived:"Driver arrived",Completed:"Completed",Failed:"Attempt not completed",Cancelled:"Cancelled"};
