import { context } from "@/lib/domain/context";
export async function GET(_request:Request,{params}:{params:Promise<{id:string}>}) {
 const {db,unit}=await context();const {id}=await params;
 if(!/^[a-f0-9]{64}$/.test(id))return new Response(null,{status:404});
 const {data,error}=await db.storage.from("quote-images").download(`${unit}/${id}`);
 if(error||!data)return new Response(null,{status:404});
 return new Response(data,{headers:{"Content-Type":data.type,"Cache-Control":"private, no-store","X-Content-Type-Options":"nosniff"}});
}
