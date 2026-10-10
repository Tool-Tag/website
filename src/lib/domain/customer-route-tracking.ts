export type CustomerRouteStop = {position:number;status:string;is_customer:boolean};
export type CustomerRoute = {leg:"Pickup"|"Return";date:string;stops:CustomerRouteStop[];total:number;resolved:number;remaining_to_customer:number;own_status:string;scheduled_eta:string|null;estimated_eta:string|null;estimate_updated_at:string|null;updated_at:string|null;closed:boolean;paused:boolean;window_start:string;window_end:string};
export const resolvedStop=(status:string)=>["Completed","Failed","Cancelled"].includes(status);
export function routeProgress(stops:CustomerRouteStop[]){
 const done=stops.filter(s=>resolvedStop(s.status));
 const current=stops.filter(s=>["En Route","Arrived"].includes(s.status));
 const upcoming=stops.filter(s=>!resolvedStop(s.status)&&!["En Route","Arrived"].includes(s.status));
 return {done,current,upcoming,percentage:stops.length?Math.round(done.length/stops.length*100):0};
}
export const spanishStopStatus:Record<string,string>={Requested:"Reserva pendiente",Scheduled:"Programada","En Route":"En camino",Arrived:"El conductor llegó",Completed:"Completada",Failed:"Intento sin completar",Cancelled:"Cancelada"};

export const spanishTrackingStage:Record<string,string>={"Pending Delivery":"Entrega pendiente","Shop Pickup":"Recogida en taller","Pickup Fee":"Pago de recolección","Pickup Scheduled":"Recolección programada","Pickup In Progress":"Recolección en curso","Picked Up":"Piezas recolectadas","In Process":"En preparación",Engraving:"Grabado","Final Details":"Detalles finales","Delivery In Progress":"Entrega en preparación","Return Scheduled":"Entrega programada","Out for Delivery":"En camino para entrega",Delivered:"Entregado",Cancelled:"Cancelado","Cancellation Balance":"Saldo de cancelación",Completed:"Terminado","Receiving Evidence":"Registro de recepción",Preparation:"Preparación"};
export function jobTimelineProgress(steps:string[],current:string){
 const operational=["Pending Delivery","Shop Pickup"].includes(current)?"Delivery In Progress":current;
 const index=Math.max(0,steps.indexOf(operational));const completed=current==="Completed"?steps.length:index;
 return {done:steps.slice(0,completed),upcoming:current==="Completed"?[]:steps.slice(index+1),percentage:steps.length?Math.round(completed/steps.length*100):0};
}
