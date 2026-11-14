import type {WorkspaceAttention} from "./workspace-attention";

/** Presentation links remain restricted to the same permitted queues as the sidebar. */
export function workspaceQueueLinks(attention:WorkspaceAttention|undefined,allowedPaths:readonly string[]) {
 if(!attention)return [];
 return [
  {label:'Get Tagged Requests',count:attention.getTagged,href:'/app/get-tagged'},
  {label:'Quotes',count:attention.quotes,href:'/app/quotes'},
  {label:'Jobs',count:attention.jobs,href:'/app/jobs'},
  {label:'Support',count:attention.notifications,href:'/app/support'},
  {label:'Refunds',count:attention.refunds,href:'/app/refunds'},
  {label:'Lost',count:attention.lost,href:'/app/lost'},
 ].filter(row=>allowedPaths.includes(row.href)&&Number.isSafeInteger(row.count)&&row.count>0);
}
