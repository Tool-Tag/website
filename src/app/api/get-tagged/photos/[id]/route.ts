import {requirePermission} from "@/lib/domain/context";
import {intakeStorage} from "@/lib/public/intake-photos";
export async function GET(_request:Request,{params}:{params:Promise<{id:string}>}){
 try{await requirePermission("quotes.view");const {id}=await params;if(!/^[a-f0-9-]{36}$/i.test(id))return new Response("Not found",{status:404});
 const db=intakeStorage(),row=await db.from("get_tagged_tool_photos").select("storage_path,mime_type").eq("id",id).eq("stored",true).single();if(!row.data)return new Response("Not found",{status:404});
 const file=await db.storage.from("tooltag-files").download(row.data.storage_path);if(!file.data)return new Response("Not found",{status:404});
 return new Response(file.data,{headers:{"Content-Type":row.data.mime_type,"Content-Disposition":"inline","Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff"}});
 }catch{return new Response("Not available",{status:403});}
}
