export const SHOP_FLOOR_STAGES=['Reception','Verification','Falcon Queue','In Process','Ready for pickup/delivery'] as const;
export type ShopFloorStage=typeof SHOP_FLOOR_STAGES[number];
export function shopFloorStage(job:{status:string;work_stage:string}):ShopFloorStage|null{
 if(['Cancelled','Completed'].includes(job.status)||['Closed','Issue Review','Payment','Payment Verification','Awaiting Delivery Acceptance'].includes(job.work_stage))return null;
 if(job.status==='Ready for Delivery'||job.work_stage==='Delivery In Progress')return 'Ready for pickup/delivery';
 if(job.work_stage==='Received at Shop')return 'Verification';
 if(job.work_stage==='Preparing')return 'Falcon Queue';
 if(['Engraving','Final Evidence','Final Details'].includes(job.work_stage))return 'In Process';
 if(['Receiving Evidence','Not Started'].includes(job.work_stage))return 'Reception';
 return null;
}
export function sortShopFloor<T extends {arrivalSort:string;code:string;id:string}>(jobs:T[]):T[]{return [...jobs].sort((a,b)=>Date.parse(a.arrivalSort)-Date.parse(b.arrivalSort)||a.code.localeCompare(b.code)||a.id.localeCompare(b.id));}

/** Both all-stage sections and a filtered grid consume the same explicitly ordered data. */
export function shopFloorGroups<T extends {stage:ShopFloorStage;arrivalSort:string;code:string;id:string}>(jobs:T[],filter:ShopFloorStage|'All stages'='All stages'){
 const ordered=sortShopFloor(jobs);
 return SHOP_FLOOR_STAGES.filter(stage=>filter==='All stages'||stage===filter).map(stage=>({stage,jobs:ordered.filter(job=>job.stage===stage)}));
}
