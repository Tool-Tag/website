import { gmailMime, MailFailure, mailEnabled } from "./gmail";
type Env = Record<string, string | undefined>;
export type Department = "support" | "hello";
export type GmailPart = { mimeType?: string; body?: { data?: string }; parts?: GmailPart[]; headers?: { name: string; value: string }[] };
export type GmailIncoming = { id: string; threadId: string; internalDate: string; labelIds?: string[]; payload?: GmailPart };
export type IncomingSupport = { mailbox: Department; sender_email: string; sender_name: string; gmail_message_id: string; gmail_thread_id: string; rfc_message_id: string; in_reply_to: string; references_header: string; subject: string; body: string; sent_at: string };
export type SupportReply = { id: string; mailbox: Department; to: string; subject: string; body: string; message_id: string; thread_id: string; in_reply_to: string; references: string };
export function supportAddresses(env: Env = process.env) {
 const aliases = { support: env.TOOLTAG_INBOX_SUPPORT_ADDRESS || "support@tooltag.martinlab.studio", hello: env.TOOLTAG_INBOX_HELLO_ADDRESS || "hello@tooltag.martinlab.studio" };
 const reserved = [env.TOOLTAG_MAIL_QUOTES_FROM || "quotes@tooltag.martinlab.studio",env.TOOLTAG_MAIL_BILLING_FROM || "billing@tooltag.martinlab.studio"].map(a=>a.toLowerCase());
 if (aliases.support.toLowerCase() === aliases.hello.toLowerCase() || Object.values(aliases).some(a=>! /^[^\s<>@,;]+@[^\s<>@,;]+\.[^\s<>@,;]+$/.test(a) || reserved.includes(a.toLowerCase()))) throw new MailFailure("SUPPORT_ALIAS_INVALID");
 return aliases;
}
export function supportEnabled(env: Env = process.env) {
 return env.TOOLTAG_SUPPORT_INBOX_ENABLED === "true" && env.NODE_ENV === "production" && (!env.VERCEL_ENV || env.VERCEL_ENV === "production") && !!(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET && env.GOOGLE_REFRESH_TOKEN);
}
export function supportReplyEnabled(env: Env = process.env) { return supportEnabled(env) && mailEnabled(env); }
function header(part: GmailPart | undefined, name: string) { return part?.headers?.find(h => h.name.toLowerCase() === name.toLowerCase())?.value || ""; }
function address(value: string) { const match = value.match(/(?:<)?([A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,})(?:>)?/i); return match?.[1].toLowerCase() || ""; }
function parts(part: GmailPart | undefined): GmailPart[] { return part ? [part,...(part.parts || []).flatMap(p => parts(p))] : []; }
function cleanHeader(value: string) { return value.replace(/[\r\n\0]/g," ").slice(0,5000); }
export function parseSupportMessage(m: GmailIncoming, env: Env = process.env): IncomingSupport | null {
 if (m.labelIds?.some(l => ["SENT","DRAFT","TRASH","SPAM"].includes(l))) return null;
 const aliases = supportAddresses(env), sender = address(header(m.payload,"From"));
 if (!sender || Object.values(aliases).some(a => a.toLowerCase() === sender)) return null;
 // Only these explicit recipients are ingested; quotes/billing mail is never imported by case subject alone.
 const recipients = [header(m.payload,"To"),header(m.payload,"Cc"),header(m.payload,"Delivered-To")].join(",").toLowerCase();
 const mailbox = (Object.keys(aliases) as Department[]).find(k => recipients.split(/[\s<>,;]+/).includes(aliases[k].toLowerCase()));
 if (!mailbox) return null;
 const all = parts(m.payload), plain = all.find(p => p.mimeType === "text/plain" && p.body?.data), html = all.find(p => p.mimeType === "text/html" && p.body?.data);
 let body = Buffer.from((plain || html)?.body?.data || "", "base64url").toString("utf8");
 if (!plain) body = body.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,"").replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi,"").replace(/<[^>]+>/g," ").replace(/&nbsp;/g," ").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&amp;/g,"&");
 const date = Number(m.internalDate); if (!Number.isFinite(date) || date <= 0) return null;
 return { mailbox, sender_email: sender, sender_name: cleanHeader(header(m.payload,"From").replace(/<[^>]+>/g,"").replace(/^"|"$/g,"")).slice(0,200), gmail_message_id: m.id, gmail_thread_id: m.threadId, rfc_message_id: cleanHeader(header(m.payload,"Message-ID")), in_reply_to: cleanHeader(header(m.payload,"In-Reply-To")), references_header: cleanHeader(header(m.payload,"References")), subject: cleanHeader(header(m.payload,"Subject")), body: body.slice(0,100000), sent_at: new Date(date).toISOString() };
}
export function supportMime(reply: SupportReply, env: Env = process.env) {
 const alias = supportAddresses(env)[reply.mailbox];
 const base = gmailMime({from:`ToolTag ${reply.mailbox === "support" ? "Support" : "Hello"} <${alias}>`,replyTo:alias,to:reply.to,subject:reply.subject,text:reply.body,html:`<pre>${reply.body.replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"})[c]!)}</pre>`},reply.id);
 const safeIds = (v: string) => v.match(/<[^<>\s\r\n]+>/g)?.slice(-20).join(" ") || "";
 const extra = [reply.in_reply_to && `In-Reply-To: ${safeIds(reply.in_reply_to)}`,reply.references && `References: ${safeIds(reply.references)}`].filter(Boolean);
 return base.replace(/^Message-ID: .*$/m,`Message-ID: ${supportMessageId(reply.id)}`).replace("MIME-Version: 1.0",[...extra,"MIME-Version: 1.0"].join("\r\n"));
}
export function supportMessageId(id: string) { if (!/^[0-9a-f-]{36}$/i.test(id)) throw new MailFailure("MAIL_HEADER_INVALID"); return `<${id}@tooltag.martinlab.studio>`; }
export class SupportGmail {
 private token?: string;
 constructor(private env: Env = process.env, private request: typeof fetch = fetch) {}
 async api(path: string, init: RequestInit = {}) {
  if (!supportEnabled(this.env)) throw new MailFailure("SUPPORT_INBOX_DISABLED");
  if (!this.token) {
   try {
    const r = await this.request("https://oauth2.googleapis.com/token",{method:"POST",cache:"no-store",signal:AbortSignal.timeout(10000),body:new URLSearchParams({client_id:this.env.GOOGLE_CLIENT_ID!,client_secret:this.env.GOOGLE_CLIENT_SECRET!,refresh_token:this.env.GOOGLE_REFRESH_TOKEN!,grant_type:"refresh_token"})});
    const data = await r.json(); if (!r.ok || !data.access_token) throw Error(); this.token = data.access_token;
   } catch { throw new MailFailure("GMAIL_OAUTH_FAILED"); }
  }
  let r: Response;
  try { r = await this.request(`https://gmail.googleapis.com/gmail/v1/users/me/${path}`,{...init,cache:"no-store",signal:AbortSignal.timeout(15000),headers:{Authorization:`Bearer ${this.token}`,"Content-Type":"application/json"}}); }
  catch { throw new MailFailure(init.method === "POST" ? "GMAIL_DELIVERY_UNKNOWN" : "GMAIL_READ_FAILED"); }
  if (!r.ok) throw new MailFailure(r.status>=500 && init.method === "POST" ? "GMAIL_DELIVERY_UNKNOWN" : `GMAIL_REJECTED_${r.status}`);
  try { return await r.json(); } catch { throw new MailFailure(init.method === "POST" ? "GMAIL_DELIVERY_UNKNOWN" : "GMAIL_READ_FAILED"); }
 }
 async list(since: string, page?: string, before?: string) {
  const a = supportAddresses(this.env);
  const params = new URLSearchParams({q:`{to:${a.support} to:${a.hello}} after:${Math.floor(new Date(since).getTime()/1000)}${before ? ` before:${Math.floor(new Date(before).getTime()/1000)+1}` : ""} -in:sent -in:drafts -in:spam -in:trash`,maxResults:"50"});
  if (page) params.set("pageToken",page);
  return this.api(`messages?${params}`) as Promise<{messages?: {id:string}[];nextPageToken?:string}>;
 }
 async get(id:string) { return this.api(`messages/${encodeURIComponent(id)}?format=full`) as Promise<GmailIncoming>; }
 async findSent(id:string) {
  const params = new URLSearchParams({q:`in:sent rfc822msgid:${supportMessageId(id)}`,maxResults:"1"});
  const found = await this.api(`messages?${params}`); return found.messages?.[0] ? this.get(found.messages[0].id) : null;
 }
 async send(reply:SupportReply) {
  if (!supportReplyEnabled(this.env)) throw new MailFailure("MAIL_DISABLED");
  if (this.env.TOOLTAG_MAIL_MODE === "test-delivery" && reply.to.toLowerCase() !== this.env.TOOLTAG_MAIL_TEST_RECIPIENT?.toLowerCase()) throw new MailFailure("MAIL_TEST_RECIPIENT_REQUIRED");
  const raw = Buffer.from(supportMime(reply,this.env)).toString("base64url");
  let result;
  try { result = await this.api("messages/send",{method:"POST",body:JSON.stringify({raw,threadId:reply.thread_id})}); }
  catch(error) {
   // A definite 400 can be caused by the new case subject not matching the original Gmail thread.
   // Do not retry timeout/5xx/unknown results. The new thread is linked to the same case after success.
   if (!(error instanceof MailFailure) || error.code !== "GMAIL_REJECTED_400") throw error;
   result = await this.api("messages/send",{method:"POST",body:JSON.stringify({raw})});
  }
  if (typeof result.id !== "string" || !result.id || typeof result.threadId !== "string" || !result.threadId) throw new MailFailure("GMAIL_DELIVERY_UNKNOWN");
  return {id:String(result.id),threadId:String(result.threadId)};
 }
}
