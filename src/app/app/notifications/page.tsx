import {redirect} from "next/navigation";
export default async function LegacyNotifications({searchParams}:{searchParams:Promise<{tab?:string;id?:string}>}){
 const q=await searchParams;const params=new URLSearchParams({section:q.tab==="hello"?"questions":"support"});if(q.id)params.set("id",q.id);if(q.tab==="history")params.set("tab","resolved");redirect(`/app/support?${params}`);
}
