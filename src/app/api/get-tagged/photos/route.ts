import {randomUUID} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {expenseProofError} from "@/lib/domain/expense-proof";
import {intakeStorage,intakeNetwork,validIntakePhotoSession} from "@/lib/public/intake-photos";
export async function POST(request:NextRequest){
 try{
  if(Number(request.headers.get("content-length")||0)>3300000)return NextResponse.json({error:"Use a photo up to 3 MB."},{status:413});
  const form=await request.formData(),token=String(form.get("token")||"");
  if(!validIntakePhotoSession(request,token))return NextResponse.json({error:"Refresh the request form before uploading."},{status:403});
  const file=form.get("file");if(!(file instanceof File)||file.size>3*1024*1024)return NextResponse.json({error:"Use a PNG, JPG or WebP photo up to 3 MB."},{status:400});
  const bytes=new Uint8Array(await file.arrayBuffer()),invalid=expenseProofError(file,bytes);if(invalid)return NextResponse.json({error:"Use a valid PNG, JPG or WebP tool photo up to 3 MB."},{status:400});
  const db=intakeStorage(),id=randomUUID();
  const reservation=await db.rpc("reserve_intake_photo",{p_id:id,p_key:token,p_network:intakeNetwork(request),p_mime:file.type,p_size:file.size});
  if(reservation.error||!reservation.data)return NextResponse.json({error:"Photo upload is unavailable or the upload limit was reached. You can submit without a photo."},{status:429});
  const upload=await db.storage.from("tooltag-files").upload(reservation.data,bytes,{contentType:file.type,upsert:false});
  if(upload.error){await db.from("get_tagged_tool_photos").delete().eq("id",id);return NextResponse.json({error:"Photo could not be stored. You can submit without it."},{status:503});}
  const saved=await db.from("get_tagged_tool_photos").update({stored:true}).eq("id",id);
  if(saved.error){await db.storage.from("tooltag-files").remove([reservation.data]);await db.from("get_tagged_tool_photos").delete().eq("id",id);return NextResponse.json({error:"Photo could not be linked. You can submit without it."},{status:503});}
  return NextResponse.json({id},{headers:{"Cache-Control":"no-store"}});
 }catch{return NextResponse.json({error:"Unable to upload the photo. You can submit without it."},{status:503});}
}
