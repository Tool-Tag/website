import {getTaggedHistory,type GetTaggedListRow} from "@/lib/domain/get-tagged-history";
import {WorkspacePagination} from "@/components/workspace-pagination";
import {RecordList} from "@/components/record-list";
import {paginateList} from "@/lib/domain/list-pagination";
import {denverDateTime} from "@/lib/domain/time";
import Link from "next/link";
import { requirePermission } from "@/lib/domain/context";
import { Heading, Panel, Empty } from "@/components/ui";

export const dynamic = "force-dynamic";

export default async function GetTaggedRequestsPage({searchParams}:{searchParams:Promise<{tab?:string;page?:string}>}) {
  const search=await searchParams,history=search.tab==="history";
  const { db, unit } = await requirePermission("quotes.view");
  let requests: GetTaggedListRow[] = [];
  let loadFailed = false;
  try {
    if (history) requests = await getTaggedHistory(db, unit);
    else {
      const { data, error } = await db.rpc("get_tagged_attention");
      if (error) throw new Error("Could not load pending requests.");
      requests = (data ?? []) as GetTaggedListRow[];
    }
  } catch {
    loadFailed = true;
  }

  const paging=paginateList(requests,search.page);
  const pageUrl=(page:number)=>`/app/get-tagged?tab=${history?"history":"pending"}&page=${page}`;
  return (
    <>
      <Heading
        title="Get Tagged Requests"
        subtitle={history ? "Approved, converted, and rejected public requests." : "Public requests waiting for review and pricing."}
      />

      <nav className="main-tab-list" aria-label="Request status"><Link href="/app/get-tagged" className={`main-tab ${history?"":"active"}`}>Pending</Link><Link href="/app/get-tagged?tab=history" className={`main-tab ${history?"active":""}`}>History</Link></nav>
      {loadFailed ? <p role="alert" className="notice error">Could not load {history ? "request history" : "pending requests"}.</p> : requests.length ? (
        <Panel><RecordList label="Get Tagged Request" empty="No requests in this view." rows={paging.items.map(request=>({id:request.id,title:request.name,reference:request.reference,description:`${request.service_method||'Service to be confirmed'} · ${denverDateTime(request.created_at)}`,status:request.request_status,icon:'request',details:[{label:'Reference',value:request.reference},{label:request.quote_only?'Quote created':'Received',value:denverDateTime(request.created_at)},{label:'Service',value:request.service_method||'To be confirmed'},...(request.matching?[{label:'Customer matching',value:request.matching}]:[]),{label:'Status',value:request.request_status}],actions:request.quote_only ? [{label:"Open Quote",href:`/app/quotes/${request.quote_id}`}] : [
          {label:history?"View Request":"Review Request",href:`/app/get-tagged/${request.id}`},
          ...(history&&request.quote_id?[{label:"Open Quote",href:`/app/quotes/${request.quote_id}`}]:[]),
        ]}))}/></Panel>
      ) : (
        <Empty>{history ? "No reviewed Get Tagged requests yet." : "No Get Tagged requests need attention."}</Empty>
      )}
      <WorkspacePagination label="Request pages" previous={paging.page>1 ? pageUrl(paging.page-1) : undefined} next={paging.page<paging.pages ? pageUrl(paging.page+1) : undefined} />
    </>
  );
}
