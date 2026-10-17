begin;
-- Expand the existing status domain; no accepted/sent Quote is rejected by this workflow.
alter table public.quotes drop constraint quotes_status_check;
alter table public.quotes add constraint quotes_status_check check(status in ('Draft','Sent','Viewed','Accepted','Agreement Pending','Declined','Expired','Revised','Rejected'));
create or replace function public.reject_get_tagged(p_id uuid,p_reason text default null) returns void
language plpgsql security definer set search_path='' as $$
declare u constant uuid:='10000000-0000-0000-0000-000000000002';r private.get_tagged_receipts;q public.quotes;recipient text;path text;begin
 if not private.has_block(u,'quotes.manage') then raise exception 'Quote management permission required' using errcode='42501';end if;
 if nullif(trim(p_reason),'') is null or length(trim(p_reason))>2000 then raise exception 'Enter a rejection reason (up to 2000 characters)';end if;
 select * into r from private.get_tagged_receipts where id=p_id for update;
 if r.id is null then raise exception 'Request not found';end if;
 if r.request_status='Rejected' then return;end if;
 if r.request_status not in ('Pending','Converted','Approved') then raise exception 'Request cannot be rejected';end if;
 if r.quote_id is not null then
  select * into q from public.quotes where id=r.quote_id and unit_id=u for update;
  if q.id is null or q.status<>'Draft' or q.sent_at is not null or exists(select 1 from public.jobs where flow_id=q.flow_id) then raise exception 'Only an unsent Draft Quote without a Job can be rejected';end if;
  update public.quotes set status='Rejected' where id=q.id;
 end if;
 recipient:=trim(r.details->'contact'->>'email');
 if recipient is null or recipient !~ '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+[.][^[:space:]<>@,;]+$' then raise exception 'A valid customer email is required before rejecting this request';end if;
 update private.get_tagged_receipts set request_status='Rejected',rejected_at=now(),reviewed_by=auth.uid(),rejection_reason=trim(p_reason) where id=r.id;
 select '/status/'||token into path from private.request_status_links where request_id=r.id;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(u,'REQUEST_REJECTED',r.id,recipient,'request-rejected:'||r.id,jsonb_build_object('template','notification','live_eligible',true,
 'subject','Your ToolTag request — '||r.reference,'text','Thank you for choosing ToolTag. After reviewing your request, we are unable to proceed for the following reason: '||trim(p_reason)||E'\n\nPlease reply if you have questions or would like help with another request.','action_path',path)) on conflict(dedupe_key) do nothing;
 perform private.rbac_log('get_tagged.rejected',r.id,jsonb_build_object('quote_id',r.quote_id,'reason',trim(p_reason)));
end$$;
revoke all on function public.reject_get_tagged(uuid,text) from public,anon;
grant execute on function public.reject_get_tagged(uuid,text) to authenticated;
create function public.get_tagged_history() returns jsonb
language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_block('10000000-0000-0000-0000-000000000002','quotes.view') then raise exception 'Quote access required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'reference',r.reference,'name',r.details->'contact'->>'name','created_at',r.created_at,'quote_id',r.quote_id,'matching',r.matching,'request_status',r.request_status,'service_method',r.details->'service'->>'method','rejection_reason',r.rejection_reason) order by r.rejected_at desc,r.id),'[]') from private.get_tagged_receipts r where r.request_status='Rejected');
end$$;
revoke all on function public.get_tagged_history() from public,anon;
grant execute on function public.get_tagged_history() to authenticated;
notify pgrst,'reload schema';
commit;
