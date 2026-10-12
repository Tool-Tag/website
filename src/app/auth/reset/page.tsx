import { CredentialReset } from "./reset-form";
import { supabase } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
export default async function ResetCredentials() {
 const db=await supabase();const {data:{user}}=await db.auth.getUser();if(!user)redirect("/login");
 return <main className="content"><h1>Set your password</h1><CredentialReset/></main>;
}
