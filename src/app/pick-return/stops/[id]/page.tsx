import {redirect} from "next/navigation";
import {context} from "@/lib/domain/context";
export const dynamic="force-dynamic";
export default async function PickReturnStopPage({params}:{params:Promise<{id:string}>}) {
 const {id}=await params;
 const {db,unit}=await context();
 const {data:stop}=await db.from("pick_return_stops").select("route_id").eq("id",id).eq("unit_id",unit).maybeSingle();
 if(!stop) redirect("/pick-return");
 const {data:route}=await db.from("pick_return_routes").select("leg").eq("id",stop.route_id).eq("unit_id",unit).maybeSingle();
 redirect(`/pick-return?mode=${route?.leg === "Pickup" ? "pickup" : "return"}&route=${stop.route_id}`);
}
