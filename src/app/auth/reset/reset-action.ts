"use server";
import {supabase} from "@/lib/supabase/server";
import {redirect} from "next/navigation";
export async function updatePassword(_: {error?:string},form:FormData):Promise<{error?:string}>{
 const password=String(form.get("password")||"");if(password.length<12||password!==form.get("confirm"))return {error:"Use at least 12 characters and matching passwords."};
 const db=await supabase();const {data:{user}}=await db.auth.getUser();if(!user)return {error:"Open your invitation or recovery link again."};
 const {error}=await db.auth.updateUser({password});if(error)return {error:"Password could not be updated. Open a fresh recovery link."};redirect("/app");
}
