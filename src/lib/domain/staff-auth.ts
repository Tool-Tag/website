export function isStaffAuthEntry(path:string){return path==='/auth/callback'||path==='/auth/complete';}
/** Only fixed, same-origin destinations are allowed after a staff Auth callback. */
export function staffAuthDestination(next:string|null){return next==='/auth/reset'?'/auth/reset':'/app';}
export function staffAuthContinuation(origin:string,next:string|null){
 const url=new URL('/auth/complete',origin);url.searchParams.set('next',staffAuthDestination(next));return url;
}
const INVALID_LINK='This invitation or recovery link is invalid or expired. Ask the ToolTag Owner for a new recovery email.';
export type StaffAuthResult={ok:true;destination:'/auth/reset'}|{ok:false;error:string};
type InvitationAuth={
 setSession(tokens:{access_token:string;refresh_token:string}):PromiseLike<{error:unknown}>;
 getUser():PromiseLike<{data:{user:{id:string}|null};error:unknown}>;
};
/** Default invite emails use a fragment, which is never available to a server Route Handler. */
export async function completeStaffAuth(fragment:string,auth:InvitationAuth):Promise<StaffAuthResult>{
 try{
  const params=new URLSearchParams(fragment.replace(/^#/,''));
  const type=params.get('type'),access=params.get('access_token'),refresh=params.get('refresh_token');
  if(params.has('error')||params.has('error_code')||!['invite','recovery'].includes(type??'')||!access||!refresh)return {ok:false,error:INVALID_LINK};
  const session=await auth.setSession({access_token:access,refresh_token:refresh});
  if(session.error)return {ok:false,error:INVALID_LINK};
  // Validate against Auth, rather than trusting a URL fragment or a cached local session.
  const verified=await auth.getUser();
  if(verified.error||!verified.data.user)return {ok:false,error:INVALID_LINK};
  return {ok:true,destination:'/auth/reset'};
 }catch{return {ok:false,error:INVALID_LINK};}
}

/** Never send production staff links to an implicit localhost/deployment-host fallback. */
export function staffPasswordRedirect(configured:string|undefined,allowLocal=false):string|null{
 try{
  if(!configured?.trim())return null;
  const site=new URL(configured.trim());
  if(site.username||site.password||site.search||site.hash||!['','/'].includes(site.pathname))return null;
  const local=['localhost','127.0.0.1','[::1]'].includes(site.hostname);
  if(local&&!allowLocal)return null;
  if(site.protocol!=='https:'&&!(allowLocal&&local&&site.protocol==='http:'))return null;
  return `${site.origin}/auth/callback?next=/auth/reset`;
 }catch{return null;}
}
