import {requirePermission} from '@/lib/domain/context';
import {shopFloorStage} from '@/lib/domain/shop-floor';
import {ShopFloorBoard,type ShopFloorJob} from '@/components/shop-floor-board';
import {Heading} from '@/components/ui';
import {StatusRefresh} from '@/components/status-refresh';
export const dynamic='force-dynamic';
export default async function ShopFloor(){
 const {db,unit}=await requirePermission('jobs.view','production.work');
 const results=await Promise.all(['jobs','job_items','commercial_flows','customers','quotes','pick_return_stops','pick_return_routes'].map(async table=>{
  // Stable paging avoids silently losing pieces/jobs at the API's default row cap.
  const result=await db.from(table).select('*').eq('unit_id',unit).order('id').range(0,999);
  if(result.error)return result;
  let pageSize=result.data.length;
  for(let offset=1000;pageSize===1000;offset+=1000){
   const page=await db.from(table).select('*').eq('unit_id',unit).order('id').range(offset,offset+999);
   if(page.error)return page;
   pageSize=page.data.length;result.data.push(...page.data);
  }
  return result;
 }));
 if(results.some(result=>result.error))throw new Error('Could not load Shop Floor.');
 const [jobs,items,flows,customers,quotes,stops,routes]=results.map(result=>result.data??[]);
 const rows:ShopFloorJob[]=jobs.filter(j=>!j.is_lost&&shopFloorStage(j)).map(job=>{
  const pieces=items.filter(i=>i.job_id===job.id&&i.stage!=='Cancelled');const received=pieces.map(i=>i.shop_received_at).filter((v):v is string=>Boolean(v)).sort((a,b)=>Date.parse(a)-Date.parse(b));
  const routeArrivals=stops.filter(s=>s.job_id===job.id).map(s=>routes.find(r=>r.id===s.route_id&&r.leg==='Pickup')?.confirmed_at).filter((v):v is string=>Boolean(v)).sort((a,b)=>Date.parse(a)-Date.parse(b));
  const arrival=received[0]??routeArrivals[0]??null;const flow=flows.find(f=>f.id===job.flow_id);
  return {id:job.id,code:job.code,customer:customers.find(c=>c.id===flow?.customer_id)?.name??'Customer',stage:shopFloorStage(job)!,arrival,arrivalSort:arrival??job.created_at,items:pieces.map(i=>({article:i.article,sequence:i.sequence,stage:i.stage})),notes:quotes.find(q=>q.id===job.quote_id)?.notes??''};
 });
 return <><StatusRefresh/><Heading title="Shop Floor" subtitle="From reception to ready — every piece, in order."/><ShopFloorBoard jobs={rows}/></>;
}
