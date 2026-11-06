/** Explicit mailbox partition: never infer a mailbox from case numbering or tab labels. */
export function supportMailboxMatches(mailbox: string, questions: boolean): boolean {
 return mailbox === (questions ? "hello" : "support");
}
/** Human-readable snapshot, excluding internal identifiers and transport metadata. */
export function supportContextLines(context: unknown, prefix=""): {label:string;value:string}[] {
 if(!context || typeof context!=="object")return [];
 return Object.entries(context).flatMap(([key,value])=>{
  if(/(^id$|_id$|token|secret|gmail|storage|bucket|provider|uuid)/i.test(key)||value===null||value===undefined)return [];
  const label=[prefix,key.replaceAll("_"," ")].filter(Boolean).join(" · ");
  if(Array.isArray(value))return value.flatMap((entry,index)=>typeof entry==="object"?supportContextLines(entry,`${label} ${index+1}`):[{label,value:String(entry)}]);
  if(typeof value==="object")return supportContextLines(value,label);
  if(typeof value==="string"&&/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(value))return [];
  return [{label,value:String(value)}];
 });
}
