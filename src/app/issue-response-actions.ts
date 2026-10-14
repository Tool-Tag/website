"use server";
import {requirePermission} from "@/lib/domain/context";
import {revalidatePath} from "next/cache";
export async function recordIssueResponse(job:string){
 try{const {db}=await requirePermission("jobs.manage");const {error}=await db.rpc("record_issue_response",{p_job:job});if(error)return {error:"Could not record the customer response."};revalidatePath(`/app/jobs/${job}`);return {ok:true};}
 catch{return {error:"You do not have permission to record a response."};}
}
