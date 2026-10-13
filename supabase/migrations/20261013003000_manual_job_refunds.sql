-- Local batch: manual-only Job refunds; no provider transfer from this migration.
begin;
create table public.refund_requests (
 id uuid primary key default gen_random_uuid(),unit_id uuid not null references public.business_units(id),job_id uuid not null references public.jobs(id),
 request_key uuid unique not null default gen_random_uuid(),payload_hash text,amount numeric(14,2) not null check(amount>0),processed_amount numeric(14,2) not null default 0 check(processed_amount>=0 and processed_amount<=amount),
 reason text not null check(reason in ('Customer cancellation','ToolTag error','Driver-down $5','Driver-down $10','Damage','Other')),
 original_method text,method text check(method in ('Zelle','Venmo','Card','Bank Transfer','Check')),
 status text not null default 'Pending' check(status in ('Pending','Completed','Cancelled')),
 issue_event text check(issue_event in ('Pickup','Return','Delivery','Completion notice')),issue_event_at timestamptz,reported_at timestamptz not null default now(),requested_at timestamptz not null default now(),confirmed_at timestamptz,confirmed_by uuid references auth.users(id),processed_at timestamptz,processed_by uuid references auth.users(id),
 process_not_before date,process_due date,accounting_period date not null default date_trunc('month',now() at time zone 'America/Denver')::date,
 proof_document_id uuid references public.documents(id),reference text,notes text not null default '',source_kind text not null default 'Manual',source_id uuid,
 requires_review boolean not null default false,confirmation_snapshot jsonb,transaction_ids uuid[] not null default '{}',unique(source_kind,source_id)
);
create index refund_requests_job on public.refund_requests(unit_id,job_id,requested_at desc);
alter table public.refund_requests enable row level security;
revoke all on public.refund_requests from public,anon,authenticated;
grant select on public.refund_requests to authenticated;
create policy refund_requests_read on public.refund_requests for select to authenticated using(private.has_any(unit_id,array['payments.refund','payments.view']));
alter table public.documents add column refund_request_id uuid references public.refund_requests(id);
alter table public.transactions drop constraint transactions_payment_method_check;
alter table public.transactions add constraint transactions_payment_method_check check(payment_method in ('Cash','Zelle','Venmo','Bank Transfer','Card','Other','Check'));
alter table public.route_compensations drop constraint route_compensations_status_check;
alter table public.route_compensations add constraint route_compensations_status_check check(status in ('Pending','Processing','ManualRequired','ReviewRequired','Completed','Cancelled'));
alter table public.cancellation_requests drop constraint cancellation_requests_refund_status_check;
alter table public.cancellation_requests add constraint cancellation_requests_refund_status_check check(refund_status in ('None','Pending','Completed','Cancelled'));
create function private.refund_business_date(p_date date,p_days integer) returns date language plpgsql immutable set search_path='' as $$declare d date:=p_date;n integer:=0;begin
 while n<p_days loop d:=d+1;if extract(isodow from d)<6 then n:=n+1;end if;end loop;return d;
end$$;
create function private.job_refund_available(p_job uuid) returns numeric language sql stable security definer set search_path='' as $$
 select coalesce(sum(t.amount-coalesce((select sum(rt.amount) from public.refunds r join public.transactions rt on rt.id=r.transaction_id where r.original_id=t.id and rt.status<>'Voided'),0)),0)
 from public.collections c join public.transactions t on t.id=c.transaction_id where t.status<>'Voided' and c.sale_id in
 (select transaction_id from public.sales where job_id=p_job union select sale_id from public.job_extensions where job_id=p_job union select sale_id from public.delivery_attempt_fees where job_id=p_job);
$$;
create function private.refund_original_method(p_job uuid) returns text language sql stable security definer set search_path='' as $$
 select t.payment_method from public.collections c join public.transactions t on t.id=c.transaction_id where t.status<>'Voided' and c.sale_id in
 (select transaction_id from public.sales where job_id=p_job union select sale_id from public.job_extensions where job_id=p_job union select sale_id from public.delivery_attempt_fees where job_id=p_job) order by t.created_at desc,t.id desc limit 1;
$$;
create function private.refund_issue_events(p_job uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('Pickup',o.picked_up_at,'Return',o.returned_at,'Delivery',j.delivered_at,'Completion notice',coalesce((select min(sent_at) from public.notifications where entity_id=j.id and event in ('JOB_READY','Completion acknowledgment') and status='Sent'),j.completion_email_sent_at)) from public.jobs j left join public.pick_return_orders o on o.job_id=j.id where j.id=p_job;
$$;
revoke all on function private.refund_issue_events(uuid) from public,anon,authenticated;
create function public.create_refund_request(p jsonb) returns uuid language plpgsql security definer set search_path='' as $$declare j public.jobs;amt numeric:=round((p->>'amount')::numeric,2);available numeric;original text;result uuid;event_at timestamptz;reported timestamptz:=coalesce((p->>'reported_at')::timestamptz,now());begin
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 select * into j from public.jobs where id=(p->>'job_id')::uuid for update;
 if j.id is null or j.unit_id<>'10000000-0000-0000-0000-000000000002' then raise exception 'Select a ToolTag Job';end if;
 if not private.has_block(j.unit_id,'payments.refund') then raise exception 'Refund permission required' using errcode='42501';end if;
 perform 1 from public.business_units where id=j.unit_id for update;
 select id into result from public.refund_requests where request_key=(p->>'request_key')::uuid and job_id=j.id;if result is not null then if (select payload_hash from public.refund_requests where id=result) is distinct from encode(sha256(convert_to((p-'request_key')::text,'UTF8')),'hex') then raise exception 'Request key already used for different refund information';end if;return result;end if;
 event_at:=coalesce((private.refund_issue_events(j.id)->>(p->>'issue_event'))::timestamptz,(p->>'issue_event_at')::timestamptz);
 if p->>'issue_event' is null or event_at is null or event_at>reported or reported>now() or (reported at time zone 'America/Denver')::date>(event_at at time zone 'America/Denver')::date+14 then raise exception 'The issue must be reported within 14 days of delivery';end if;
 available:=private.job_refund_available(j.id)-coalesce((select sum(amount-processed_amount) from public.refund_requests where job_id=j.id and status='Pending'),0);
 if amt is null or amt<=0 or amt<>((p->>'amount')::numeric) or amt>available then raise exception 'Refund exceeds the unreserved amount actually paid';end if;
 original:=private.refund_original_method(j.id);
 insert into public.refund_requests(unit_id,job_id,request_key,amount,reason,original_method,method,issue_event,issue_event_at,reported_at,notes)
 values(j.unit_id,j.id,(p->>'request_key')::uuid,amt,p->>'reason',original,coalesce(nullif(p->>'method',''),case when original in ('Zelle','Venmo','Card','Bank Transfer','Check') then original end),p->>'issue_event',event_at,reported,left(coalesce(p->>'notes',''),5000)) returning id into result;
 update public.refund_requests set payload_hash=encode(sha256(convert_to((p-'request_key')::text,'UTF8')),'hex') where id=result;
 perform private.rbac_log('refund.requested',result,jsonb_build_object('job_id',j.id,'amount',amt));return result;
end$$;
create function public.refund_job_choices() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_any('10000000-0000-0000-0000-000000000002',array['payments.refund','payments.view']) then raise exception 'Refund access required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',j.id,'code',j.code,'quote_code',q.code,'original_method',private.refund_original_method(j.id),'issue_events',private.refund_issue_events(j.id),'original_account_id',(select t.account_id from public.collections c join public.transactions t on t.id=c.transaction_id where t.status<>'Voided' and c.sale_id in(select transaction_id from public.sales where job_id=j.id union select sale_id from public.job_extensions where job_id=j.id union select sale_id from public.delivery_attempt_fees where job_id=j.id) order by t.created_at desc,t.id desc limit 1),'available',greatest(0,private.job_refund_available(j.id)-coalesce((select sum(amount-processed_amount) from public.refund_requests r where r.job_id=j.id and r.status='Pending'),0)))) from public.jobs j join public.quotes q on q.id=j.quote_id where j.unit_id='10000000-0000-0000-0000-000000000002'),'[]');
end$$;
-- Account names only: refund staff do not need access to balances or other finance data.
create function public.refund_account_choices() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not private.has_any('10000000-0000-0000-0000-000000000002',array['payments.refund','payments.view']) then raise exception 'Refund access required' using errcode='42501';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by name) from public.accounts where unit_id='10000000-0000-0000-0000-000000000002' and active),'[]');
end$$;
revoke all on function public.refund_account_choices() from public,anon;
grant execute on function public.refund_account_choices() to authenticated;
-- Registry mirrors existing obligations; no historical payment or notification replay.
create function private.sync_refund_source() returns trigger language plpgsql security definer set search_path='' as $$declare amt numeric;paid numeric;kind text;reason text;original text;st text;requested timestamptz;ref text;begin
 if new.unit_id<>'10000000-0000-0000-0000-000000000002' then return new;end if;
 if TG_TABLE_NAME='route_compensations' then
 amt:=new.amount;paid:=new.paid_amount;kind:='Route';reason:=case when amt=5 then 'Driver-down $5' else 'Driver-down $10' end;original:=new.method;st:=case when new.status='Completed' then 'Completed' when new.status='Cancelled' then 'Cancelled' else 'Pending' end;requested:=now();ref:=new.provider_reference;
 else
 if new.refund_eligible_amount<=0 or new.refund_status='None' then return new;end if;
 amt:=new.refund_eligible_amount;paid:=case when new.refund_status='Completed' then amt else 0 end;kind:='Cancellation';reason:='Customer cancellation';original:=private.refund_original_method(new.job_id);st:=new.refund_status;requested:=new.requested_at;ref:=null;
 end if;
 insert into public.refund_requests(unit_id,job_id,amount,processed_amount,reason,original_method,method,status,requested_at,reported_at,source_kind,source_id,requires_review,reference)
 values(new.unit_id,new.job_id,amt,least(paid,amt),reason,original,case when original in ('Zelle','Venmo','Card','Bank Transfer','Check') then original end,st,requested,requested,kind,new.id,case when TG_TABLE_NAME='route_compensations' then new.status in ('Processing','ReviewRequired') else false end,ref)
 on conflict(source_kind,source_id) do update set amount=excluded.amount,processed_amount=excluded.processed_amount,reason=excluded.reason,status=excluded.status,requires_review=excluded.requires_review,confirmed_at=case when excluded.amount>refund_requests.amount then null else refund_requests.confirmed_at end,confirmed_by=case when excluded.amount>refund_requests.amount then null else refund_requests.confirmed_by end,process_not_before=case when excluded.amount>refund_requests.amount then null else refund_requests.process_not_before end,process_due=case when excluded.amount>refund_requests.amount then null else refund_requests.process_due end;
 return new;
end$$;
create trigger route_refund_registry after insert or update of amount,paid_amount,status on public.route_compensations for each row execute function private.sync_refund_source();
create trigger cancellation_refund_registry after insert or update of refund_status,refund_eligible_amount on public.cancellation_requests for each row execute function private.sync_refund_source();
-- Backfill directly: never update legacy operational rows or replay their triggers.
insert into public.refund_requests(unit_id,job_id,amount,processed_amount,reason,original_method,method,status,source_kind,source_id,requires_review)
select unit_id,job_id,amount,paid_amount,case when amount=5 then 'Driver-down $5' else 'Driver-down $10' end,method,case when method in ('Zelle','Venmo','Card','Bank Transfer','Check') then method end,case when status='Completed' then 'Completed' else 'Pending' end,'Route',id,status in ('Processing','ReviewRequired') from public.route_compensations where unit_id='10000000-0000-0000-0000-000000000002';
insert into public.refund_requests(unit_id,job_id,amount,processed_amount,reason,original_method,method,status,requested_at,reported_at,source_kind,source_id)
select unit_id,job_id,refund_eligible_amount,case when refund_status='Completed' then refund_eligible_amount else 0 end,'Customer cancellation',private.refund_original_method(job_id),case when private.refund_original_method(job_id) in ('Zelle','Venmo','Card','Bank Transfer','Check') then private.refund_original_method(job_id) end,refund_status,requested_at,requested_at,'Cancellation',id from public.cancellation_requests where unit_id='10000000-0000-0000-0000-000000000002' and refund_eligible_amount>0 and refund_status in ('Pending','Completed');
-- Automatic means creating the obligation; money is always processed by staff.
create or replace function public.claim_route_refunds() returns jsonb language plpgsql security definer set search_path='' as $$begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;return '[]'::jsonb;
end$$;
do $$declare d text;begin
 select pg_get_functiondef('public.driver_incident_choice(uuid,text,text)'::regprocedure) into d;
 d:=replace(d,'update public.route_incident_jobs set choice=p_choice where incident_id=i.id and job_id=j.id;','update public.route_incident_jobs set choice=p_choice where incident_id=i.id and job_id=j.id; perform private.queue_route_compensation(i.id,j.id,case when p_choice=''Wait'' then 5 else 10 end);');execute d;
end$$;
-- Preserve the generic action gate while granting refund staff scoped proof uploads.
do $$declare d text;name text;begin
 select pg_get_functiondef('private.rbac_action_blocks(text)'::regprocedure) into d;
 foreach name in array array['register_document_metadata','finish_document_storage','update_document_evidence_metadata'] loop
 d:=replace(d,quote_literal(name)||',array[',quote_literal(name)||',array[''payments.refund'',');end loop;execute d;
end$$;
-- Customer messaging reflects manual processing; contractual text is untouched.
do $$declare d text;begin
 select pg_get_functiondef('public.report_driver_incident(uuid)'::regprocedure) into d;
 d:=replace(d,'Refunds go back to your original payment method when its provider supports automatic refunds; otherwise ToolTag must issue the payment.','ToolTag processes approved refunds manually within 5–7 business days after confirmation. We normally use the original electronic payment method; cash payments require an electronic method or check.');execute d;
end$$;
-- Proof uploads reuse the existing private Storage path and staff authorization.
do $$declare d text;begin
 select pg_get_functiondef('private.require_evidence(jsonb)'::regprocedure) into d;
 d:=regexp_replace(d,'\mbegin\M',$guard$begin if nullif(p->>'refund_request_id','') is not null then
 if p->>'type'<>'Refund Review Evidence' or not private.has_block((p->>'unit_id')::uuid,'payments.refund') or not exists(select 1 from public.refund_requests r where r.id=(p->>'refund_request_id')::uuid and r.unit_id=(p->>'unit_id')::uuid and r.job_id=(p->>'job_id')::uuid) then raise exception 'Invalid refund proof relationship or permission' using errcode='42501';end if;return;end if;$guard$,'i');execute d;
 select pg_get_functiondef('private.rbac_row(text,jsonb)'::regprocedure) into d;
 d:=replace(d,'when ''documents'' then',$guard$when 'documents' then if row_data->>'refund_request_id' is not null then return private.has_any(u,array['payments.refund','payments.view']);end if;$guard$);execute d;
 select pg_get_functiondef('public.register_document_metadata(jsonb)'::regprocedure) into d;
 d:=replace(d,'  insert into public.documents(', $guard$if nullif(p->>'refund_request_id','') is not null then logical:=logical||':refund:'||(p->>'refund_request_id');end if; insert into public.documents($guard$);
 d:=replace(d,'  return did;',$guard$if nullif(p->>'refund_request_id','') is not null then update public.documents set refund_request_id=(p->>'refund_request_id')::uuid where id=did and unit_id=u;end if; return did;$guard$);execute d;
end$$;
revoke all on function private.refund_business_date(date,integer),private.job_refund_available(uuid),private.refund_original_method(uuid),private.sync_refund_source() from public,anon,authenticated;
revoke all on function public.create_refund_request(jsonb),public.refund_job_choices() from public,anon;
grant execute on function public.create_refund_request(jsonb),public.refund_job_choices() to authenticated;
-- Block generic customer-refund mutations from bypassing the Job workflow.
-- Vendor refunds and unrelated BOFT business units retain their existing behavior.
do $$declare d text;begin
 select pg_get_functiondef('private.record_movement(jsonb)'::regprocedure) into d;
 d:=replace(d,' if original.type=''EXPENSE'' then',$guard$ if u='10000000-0000-0000-0000-000000000002' and original.type='COLLECTION' then raise exception 'Create and process customer refunds in Finance → Refunds';end if; if original.type='EXPENSE' then$guard$);execute d;
end$$;
-- Legacy callers must use the same manual workflow; no proof/date bypass.
create or replace function public.confirm_route_refund(p_id uuid,p_reference text) returns void language plpgsql security definer set search_path='' as $$begin raise exception 'Process this refund in Finance → Refunds with confirmation and proof';end$$;
alter function public.confirm_cancellation_refund(uuid,text,text) rename to confirm_cancellation_refund_before_manual_registry;
revoke all on function public.confirm_cancellation_refund_before_manual_registry(uuid,text,text) from public,anon,authenticated;
create function public.confirm_cancellation_refund(p_request uuid,p_method text,p_reference text default null) returns jsonb language plpgsql security definer set search_path='' as $$begin if exists(select 1 from public.cancellation_requests where id=p_request and unit_id<>'10000000-0000-0000-0000-000000000002') then return public.confirm_cancellation_refund_before_manual_registry(p_request,p_method,p_reference);end if;raise exception 'Process this refund in Finance → Refunds with confirmation and proof';end$$;
revoke all on function public.confirm_cancellation_refund(uuid,text,text) from public,anon;
grant execute on function public.confirm_cancellation_refund(uuid,text,text) to authenticated;
create or replace function public.finish_route_refund(p_id uuid,p_claim uuid,p_provider_id text,p_state text) returns void language plpgsql security definer set search_path='' as $$begin raise exception 'Automatic refund processing is disabled; staff must process refunds manually';end$$;
create function public.refund_request_action(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$declare
 r public.refund_requests;j public.jobs;rec record;remaining numeric;alloc numeric;tid uuid;ids uuid[]:='{}';proof uuid:=nullif(p->>'proof_id','')::uuid;v_method text:=p->>'method';v_reference text:=trim(p->>'reference');v_account uuid:=nullif(p->>'account_id','')::uuid;snap jsonb;receipt uuid;begin
 -- Unit lock serializes all reservation and completion checks.
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 select * into r from public.refund_requests where id=(p->>'id')::uuid for update;
 if r.id is null or not private.has_block(r.unit_id,'payments.refund') then raise exception 'Refund permission required' using errcode='42501';end if;
 select * into j from public.jobs where id=r.job_id for update;
 if r.status='Completed' and p->>'action'='complete' then return r.confirmation_snapshot;end if;
 if r.status<>'Pending' then raise exception 'Only pending refunds can be changed';end if;
 if p->>'action'='cancel' then
 update public.refund_requests set status='Cancelled',notes=notes||E'\nCancelled: '||left(coalesce(p->>'notes',''),2000) where id=r.id;
 if r.source_kind='Route' then update public.route_compensations set status='Cancelled' where id=r.source_id;end if;
 if r.source_kind='Cancellation' then update public.cancellation_requests set refund_status='Cancelled' where id=r.source_id;end if;
 elsif p->>'action'='confirm' then
 if r.requires_review and coalesce((p->>'reviewed')::boolean,false) is not true then raise exception 'Review prior provider activity and payment eligibility before confirming';end if;
 update public.refund_requests set confirmed_at=coalesce(confirmed_at,now()),confirmed_by=coalesce(confirmed_by,auth.uid()),requires_review=false,
 process_not_before=coalesce(process_not_before,private.refund_business_date((now() at time zone 'America/Denver')::date,5)),process_due=coalesce(process_due,private.refund_business_date((now() at time zone 'America/Denver')::date,7)) where id=r.id;
 elsif p->>'action'='complete' then
 if r.confirmed_at is null or r.requires_review then raise exception 'Confirm eligibility before processing';end if;
 if (now() at time zone 'America/Denver')::date<r.process_not_before then raise exception 'Process this refund 5–7 business days after confirmation';end if;
 if v_method is null or v_method not in ('Zelle','Venmo','Card','Bank Transfer','Check') then raise exception 'Choose an electronic method or Check; Cash refunds are not allowed';end if;
 if not exists(select 1 from public.accounts where id=v_account and unit_id=r.unit_id and active) then raise exception 'Select the account that actually funded the refund';end if;
 if coalesce(v_reference,'')='' then raise exception 'Enter the actual payment reference';end if;
 if not exists(select 1 from public.documents d where d.id=proof and d.refund_request_id=r.id and d.job_id=j.id and d.unit_id=r.unit_id and d.type='Refund Review Evidence' and d.storage_status='stored') then raise exception 'Upload and select proof belonging to this refund';end if;
 remaining:=r.amount-r.processed_amount;
 if remaining>private.job_refund_available(j.id)-coalesce((select sum(amount-processed_amount) from public.refund_requests where job_id=j.id and status='Pending' and id<>r.id),0) then raise exception 'Refund exceeds the amount actually paid and not reserved';end if;
 for rec in select t.* from public.collections c join public.transactions t on t.id=c.transaction_id where t.status<>'Voided' and c.sale_id in
 (select transaction_id from public.sales where job_id=j.id union select sale_id from public.job_extensions where job_id=j.id union select sale_id from public.delivery_attempt_fees where job_id=j.id) order by t.created_at,t.id for update of t loop
 exit when remaining<=0;
 alloc:=least(remaining,rec.amount-coalesce((select sum(rt.amount) from public.refunds rf join public.transactions rt on rt.id=rf.transaction_id where rf.original_id=rec.id and rt.status<>'Voided'),0));
 if alloc<=0 then continue;end if;
 insert into public.transactions(unit_id,account_id,type,transaction_date,amount,customer_id,description,payment_method,reference,created_by)
 values(r.unit_id,v_account,'REFUND',(now() at time zone 'America/Denver')::date,alloc,rec.customer_id,'Refund · '||j.code||' · '||r.reason,v_method,v_reference,auth.uid()) returning id into tid;
 insert into public.refunds(transaction_id,unit_id,original_id,subtype,override_reason) values(tid,r.unit_id,rec.id,'Customer Refund',r.reason||' · request '||r.id);
 ids:=array_append(ids,tid);remaining:=remaining-alloc;
 end loop;
 if remaining>0 then raise exception 'Refund exceeds refundable customer collections';end if;
 snap:=jsonb_build_object('request_id',r.id,'job_id',j.id,'quote_id',j.quote_id,'job_code',j.code,'quote_code',(select code from public.quotes where id=j.quote_id),'amount',r.amount-r.processed_amount,'cumulative_amount',r.amount,'method',v_method,'reference',v_reference,'processed_at',now(),'processed_by',auth.uid(),'account_id',v_account,'processor_name',(select coalesce(nullif(display_name,''),auth.uid()::text) from public.staff_access where unit_id=r.unit_id and user_id=auth.uid()),'transaction_ids',ids);
 update public.refund_requests set status='Completed',processed_amount=amount,method=v_method,reference=v_reference,notes=notes||case when nullif(p->>'notes','') is null then '' else E'\n'||left(p->>'notes',2000) end,processed_at=now(),processed_by=auth.uid(),proof_document_id=proof,confirmation_snapshot=snap,transaction_ids=transaction_ids||ids,accounting_period=date_trunc('month',now() at time zone 'America/Denver')::date where id=r.id;
 if r.source_kind='Route' then update public.route_compensations set paid_amount=r.amount,status='Completed' where id=r.source_id;end if;
 if r.source_kind='Cancellation' then
 update public.cancellation_requests set refund_status='Completed',refund_transaction_id=ids[1],refund_transaction_ids=ids where id=r.source_id;
 update public.pick_return_orders set fee_status='Refunded' where job_id=j.id and fee_status='Refund Pending';end if;
 insert into public.documents(unit_id,type,file_name,job_id,content_snapshot,status,uploaded_by,refund_request_id,logical_key) values(r.unit_id,'Refund Receipt','Refund_'||j.code||'.json',j.id,snap,'Available',auth.uid(),r.id,'manual-refund:'||r.id||':'||r.amount) returning id into receipt;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values(r.unit_id,'REFUND_UPDATE',j.id,private.job_customer_recipient(j.id),'manual-refund-completed:'||r.id||':'||r.amount,jsonb_build_object('template','notification','subject','Refund confirmation — '||j.code,'text','ToolTag processed your refund of $'||to_char(r.amount-r.processed_amount,'FM999999990.00')||' on '||(now() at time zone 'America/Denver')::date||' via '||v_method||'. Job: '||j.code||'. Quote: '||(snap->>'quote_code')||'. Reference: '||v_reference||'.','live_eligible',true,'confirmation',snap)) on conflict do nothing;
 else raise exception 'Invalid refund action';end if;
 perform private.rbac_log('refund.'||(p->>'action'),r.id,jsonb_build_object('job_id',j.id));return coalesce(snap,jsonb_build_object('ok',true,'job_id',j.id));
end$$;
revoke all on function public.refund_request_action(jsonb) from public,anon;
grant execute on function public.refund_request_action(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
