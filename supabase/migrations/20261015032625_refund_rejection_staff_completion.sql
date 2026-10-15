-- Forward-only extension of the reviewed manual refund lifecycle. No money moves here.
begin;
alter table public.refund_requests drop constraint refund_requests_status_check;
alter table public.refund_requests add constraint refund_requests_status_check
 check(status in ('Pending','In Review','Approved','Issued','Completed','Rejected','Cancelled'));
alter table public.refund_requests add column rejected_at timestamptz;
alter table public.refund_requests add column rejected_by uuid references auth.users(id);
alter table public.refund_requests add column rejection_reason text;
alter table public.refund_requests add column completed_by uuid references auth.users(id);
alter table public.refund_requests add column completion_channel text check(completion_channel in ('Phone','Email'));
alter table public.refund_requests add column completion_notes text;

-- Keep existing approval, payment caps, ledger, proof and customer-link logic intact.
alter function public.refund_request_action(jsonb) rename to refund_request_action_before_full_flow;
revoke all on function public.refund_request_action_before_full_flow(jsonb) from public,anon,authenticated;
create function public.refund_request_action(p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.refund_requests;v_action text:=p->>'action';v_reason text:=trim(p->>'reason');v_notes text:=trim(p->>'notes');begin
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 select * into r from public.refund_requests where id=(p->>'id')::uuid for update;
 if r.id is null or r.unit_id<>'10000000-0000-0000-0000-000000000002' or not private.has_block(r.unit_id,'payments.refund') then
  raise exception 'Refund permission required' using errcode='42501';
 end if;
 if r.status='Rejected' and v_action is distinct from 'reject' then raise exception 'History is read-only';end if;
 if v_action='reject' then
  if r.status='Rejected' then return jsonb_build_object('job_id',r.job_id);end if;
  if r.status<>'In Review' then raise exception 'Only refunds In Review can be rejected';end if;
  if coalesce(v_reason,'')='' or length(v_reason)>2000 then raise exception 'Enter a rejection reason (up to 2000 characters)';end if;
  update public.refund_requests set status='Rejected',rejected_at=now(),rejected_by=auth.uid(),rejection_reason=v_reason where id=r.id;
 elsif v_action='acknowledge' then
  if r.status='Completed' then return jsonb_build_object('job_id',r.job_id);end if;
  if r.status<>'Issued' then raise exception 'Only Issued refunds can be marked received';end if;
  if coalesce(p->>'channel','') not in ('Phone','Email') or coalesce(v_notes,'')='' or length(v_notes)>2000 then
   raise exception 'Record the customer confirmation channel (Phone or Email) and notes';end if;
  if now()>=r.acknowledgment_deadline then
   perform private.complete_refund(r.id,'No response within 5 days');
  else
   perform private.complete_refund(r.id,'Staff confirmed receipt');
   update public.refund_requests set completed_by=auth.uid(),completion_channel=p->>'channel',completion_notes=v_notes,acknowledged_at=now() where id=r.id;
  end if;
 elsif v_action='note' then
  if r.status not in ('Pending','In Review','Approved','Issued') then raise exception 'History is read-only';end if;
  if coalesce(v_notes,'')='' or length(v_notes)>2000 then raise exception 'Enter a note (up to 2000 characters)';end if;
  update public.refund_requests set notes=notes||E'\n'||now()::text||' · '||auth.uid()::text||': '||v_notes where id=r.id;
 else
  return public.refund_request_action_before_full_flow(p);
 end if;
 perform private.rbac_log('refund.lifecycle.'||v_action,r.id,jsonb_build_object('job_id',r.job_id,'reason',v_reason,'channel',p->>'channel'));
 return jsonb_build_object('job_id',r.job_id,'ok',true);
end$$;
revoke all on function public.refund_request_action(jsonb) from public,anon;
grant execute on function public.refund_request_action(jsonb) to authenticated;

-- Source reconciliation must never reopen or rewrite a terminal History record.
-- The source remains an audit record; the refund registry is the decision authority.
do $$declare d text;begin
 d:=pg_get_functiondef('private.sync_refund_source()'::regprocedure);
 d:=regexp_replace(d,'\mbegin\M',$guard$begin
 if exists(select 1 from public.refund_requests where source_id=new.id and source_kind=case when TG_TABLE_NAME='route_compensations' then 'Route' else 'Cancellation' end and status in ('Completed','Rejected')) then return new;end if;
 $guard$,'i');execute d;
 -- Only minimal customer context is exposed to authorized refund viewers.
 d:=pg_get_functiondef('public.refund_job_choices()'::regprocedure);
 d:=replace(d,'''quote_code'',q.code,','''quote_code'',q.code,''customer_name'',(select c.name from public.commercial_flows f join public.customers c on c.id=f.customer_id and c.unit_id=f.unit_id where f.id=j.flow_id and f.unit_id=j.unit_id),');execute d;
 -- Refund clocks start at eligibility confirmation, not original arrival.
 d:=pg_get_functiondef('public.urgent_login_attention()'::regprocedure);
 d:=replace(d,'r.requested_at started_at','coalesce(r.confirmed_at,now()) started_at');execute d;
 -- No new screenshots can be attached to read-only History records.
 d:=pg_get_functiondef('private.require_evidence(jsonb)'::regprocedure);
 d:=regexp_replace(d,'\mbegin\M',$guard$begin
 if nullif(p->>'refund_request_id','') is not null and exists(select 1 from public.refund_requests where id=(p->>'refund_request_id')::uuid and status in ('Completed','Rejected','Cancelled')) then raise exception 'Refund history is read-only';end if;
 $guard$,'i');execute d;
end$$;
notify pgrst,'reload schema';
commit;
