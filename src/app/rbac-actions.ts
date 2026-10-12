"use server";
import { z } from "zod";
import { revalidatePath } from "next/cache";
import { requireOwner, requirePermission } from "@/lib/domain/context";
import { storageAdmin } from "@/lib/storage/admin";
import { toolTagPublicUrl } from "@/lib/payments";
export type RbacResult = {error?: string; ok?: boolean};
export async function saveRole(_: RbacResult, form: FormData): Promise<RbacResult> {
  try {
    const {db} = await requireOwner();
    const {error} = await db.rpc("rbac_save_role", {p_id: form.get("id") || null, p_name: z.string().trim().min(1).max(80).parse(form.get("name")), p_blocks: form.getAll("blocks").map(String)});
    if (error) return {error: error.message};
    revalidatePath("/app/settings"); return {ok: true};
  } catch {return {error: "Could not save role. Owner access is required."};}
}
export async function saveStaffUser(_: RbacResult, form: FormData): Promise<RbacResult> {
  try {
    const {db} = await requireOwner();
    const {error} = await db.rpc("rbac_save_user", {p_user: z.uuid().parse(form.get("id")), p_name: String(form.get("name") || "").slice(0,100), p_active: form.get("active") === "on", p_roles: form.getAll("roles").map(value => z.uuid().parse(value))});
    if (error) return {error: error.message};
    revalidatePath("/app", "layout"); return {ok:true};
  } catch {return {error:"Could not save user access. Owner access is required."};}
}
export async function inviteStaffUser(_: RbacResult, form: FormData): Promise<RbacResult> {
  try {
    const {db} = await requireOwner();
    const email = z.email().parse(String(form.get("email") || "").trim());
    const roles = form.getAll("roles").map(value => z.uuid().parse(value));
    const directory = await db.rpc("rbac_directory");
    if (directory.error || !roles.length || roles.some(id => !directory.data?.roles?.some((r: {id:string}) => r.id === id))) return {error:"Choose valid ToolTag roles."};
    const {data,error} = await storageAdmin().auth.admin.inviteUserByEmail(email,{redirectTo:`${toolTagPublicUrl()}/auth/callback?next=/auth/reset`});
    if (error || !data.user) return {error:"Invitation could not be sent. For an existing account, add its User ID below."};
    const saved = await db.rpc("rbac_save_user",{p_user:data.user.id,p_name:String(form.get("name") || "").slice(0,100),p_active:true,p_roles:roles});
    if(saved.error) return {error:"Invitation sent, but access was not assigned. Add the invited User ID before they can enter ToolTag."};
    revalidatePath("/app/settings");return {ok:true};
  } catch {return {error:"Invitation unavailable. Check Owner access and server Auth configuration."};}
}
export async function resetStaffCredentials(_: RbacResult, form: FormData): Promise<RbacResult> {
  try {
    const {db} = await requireOwner();
    const id = z.uuid().parse(form.get("id"));
    const directory = await db.rpc("rbac_directory");
    const target = directory.data?.users?.find((u: {id:string;email:string}) => u.id===id);
    if(directory.error || !target?.email) return {error:"ToolTag user unavailable."};
    const {error} = await db.auth.resetPasswordForEmail(target.email,{redirectTo:`${toolTagPublicUrl()}/auth/callback?next=/auth/reset`});
    if(error) return {error:"Recovery email could not be sent."};
    const logged=await db.rpc("rbac_log_credential_reset",{p_user:id});
    if(logged.error)return {error:"Recovery requested, but the audit record could not be saved."};
    return {ok:true};
  } catch {return {error:"Credential reset requires Owner access."};}
}
export async function assignRouteOperator(_: RbacResult, form: FormData): Promise<RbacResult> {
  try {
    const {db} = await requirePermission("pr.routes.plan");
    const {error} = await db.rpc("assign_route_operator",{p_route:z.uuid().parse(form.get("route")),p_operator:form.get("operator") ? z.uuid().parse(form.get("operator")) : null});
    if(error) return {error:error.message};
    revalidatePath("/app/pick-return");revalidatePath("/pick-return","layout");return {ok:true};
  } catch {return {error:"Could not assign route operator."};}
}
