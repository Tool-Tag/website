begin;
alter table public.refund_requests drop constraint refund_requests_status_check;
alter table public.refund_requests add constraint refund_requests_status_check check(status in ('Pending','In Review','Approved','Issued','Completed','Cancelled'));
alter table public.refund_requests add column reviewed_at timestamptz;
alter table public.refund_requests add column reviewed_by uuid references auth.users(id);
alter table public.refund_requests add column approved_at timestamptz;
alter table public.refund_requests add column approved_by uuid references auth.users(id);
alter table public.refund_requests add column issued_at timestamptz;
alter table public.refund_requests add column acknowledgment_deadline timestamptz;
alter table public.refund_requests add column acknowledged_at timestamptz;
alter table public.refund_requests add column completed_at timestamptz;
alter table public.refund_requests add column completion_reason text;
alter table public.documents add column refund_method text check(refund_method in ('Zelle','Venmo','Card','Bank Transfer','Check'));
create table private.refund_links(refund_id uuid primary key references public.refund_requests(id),token_hash text unique not null,expires_at timestamptz not null);
alter table private.refund_links enable row level security;
revoke all on private.refund_links from public,anon,authenticated;
create function private.refund_approver() returns boolean language sql stable security definer set search_path='' as $$select private.staff_active('10000000-0000-0000-0000-000000000002') and (private.is_owner('10000000-0000-0000-0000-000000000002') or exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id and r.unit_id=ur.unit_id where ur.user_id=auth.uid() and ur.unit_id='10000000-0000-0000-0000-000000000002' and lower(trim(r.name))='manager'))$$;
create function public.refund_can_approve() returns boolean language sql stable security definer set search_path='' as $$select private.refund_approver() and private.has_block('10000000-0000-0000-0000-000000000002','payments.refund')$$;
-- Retain the audited disbursement ledger; only lifecycle boundaries change.
alter function public.refund_request_action(jsonb) rename to refund_request_action_before_lifecycle;
revoke all on function public.refund_request_action_before_lifecycle(jsonb) from public,anon,authenticated;
do $$declare d text;name text;begin
 foreach name in array array['public.create_refund_request(jsonb)','public.refund_job_choices()','public.refund_request_action_before_lifecycle(jsonb)'] loop
 d:=pg_get_functiondef(name::regprocedure);
 -- Reservation calculations must include all unpaid active stages.
 d:=replace(d,'and status=''Pending''','and status in (''Pending'',''In Review'',''Approved'',''Issued'')');
 d:=replace(d,'and r.status=''Pending''','and r.status in (''Pending'',''In Review'',''Approved'',''Issued'')');
 if name='public.refund_request_action_before_lifecycle(jsonb)' then
 d:=replace(d,'if r.status=''Completed'' and','if r.status in (''Issued'',''Completed'') and');
 d:=replace(d,'if r.status<>''Pending'' then','if r.status not in (''Pending'',''In Review'',''Approved'') then');
 d:=replace(d,'set confirmed_at=','set status=''In Review'',reviewed_at=coalesce(reviewed_at,now()),reviewed_by=coalesce(reviewed_by,auth.uid()),confirmed_at=');
 d:=replace(d,'elsif p->>''action''=''complete'' then','elsif p->>''action''=''complete'' then if r.status<>''Approved'' or r.approved_at is null then raise exception ''Owner or Manager approval is required before issuance'';end if;');
 d:=replace(d,'set status=''Completed'',processed_amount=amount','set status=''Issued'',issued_at=now(),acknowledgment_deadline=now()+interval ''5 days'',processed_amount=amount');
 d:=replace(d,'and d.storage_status=''stored''','and d.storage_status=''stored'' and d.mime_type in (''image/png'',''image/jpeg'',''image/webp'') and d.refund_method=v_method');
 end if;execute d;
 end loop;
 -- Financial source completion must not pretend the customer acknowledged receipt.
 d:=pg_get_functiondef('private.sync_refund_source()'::regprocedure);
 d:=replace(d,'status=excluded.status,requires_review=', 'status=case when excluded.amount>refund_requests.amount then ''Pending'' when refund_requests.status in (''In Review'',''Approved'',''Issued'',''Completed'') and excluded.status<>''Cancelled'' then refund_requests.status else excluded.status end,approved_at=case when excluded.amount>refund_requests.amount then null else refund_requests.approved_at end,approved_by=case when excluded.amount>refund_requests.amount then null else refund_requests.approved_by end,requires_review=');execute d;
 d:=pg_get_functiondef('public.urgent_login_attention()'::regprocedure);
 d:=replace(d,'r.status=''Pending'' and r.amount>r.processed_amount','r.status in (''Pending'',''In Review'',''Approved'',''Issued'')');execute d;
end$$;
do $$declare d text;begin
 d:=pg_get_functiondef('public.register_document_metadata(jsonb)'::regprocedure);
 d:=replace(d,$old$set refund_request_id=(p->>'refund_request_id')::uuid$old$,$new$set refund_request_id=(p->>'refund_request_id')::uuid,refund_method=p->>'refund_method'$new$);execute d;
end$$;
create function public.refund_request_action(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$declare r public.refund_requests;result jsonb;token text;path text;proof public.documents;begin
 perform 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' for update;
 select * into r from public.refund_requests where id=(p->>'id')::uuid for update;
 if r.id is null or r.unit_id<>'10000000-0000-0000-0000-000000000002' or not private.has_block(r.unit_id,'payments.refund') then raise exception 'Refund permission required' using errcode='42501';end if;
 if p->>'action'='review' then
 if r.status='In Review' then return jsonb_build_object('job_id',r.job_id);end if;
 if r.status<>'Pending' then raise exception 'Only new refunds can enter review';end if;
 update public.refund_requests set status='In Review',reviewed_at=now(),reviewed_by=auth.uid() where id=r.id;
 elsif p->>'action'='approve' then
 if not private.refund_approver() then raise exception 'Only Owner or Manager can approve refunds' using errcode='42501';end if;
 if r.status='Approved' then return jsonb_build_object('job_id',r.job_id);end if;
 if r.status<>'In Review' or r.confirmed_at is null or r.requires_review then raise exception 'Confirm eligibility during review before approval';end if;
 update public.refund_requests set status='Approved',approved_at=now(),approved_by=auth.uid() where id=r.id;
 else
 if p->>'action'='confirm' and r.status not in ('Pending','In Review') then raise exception 'Only refunds under review can confirm eligibility';end if;
 if p->>'action'='cancel' and r.status in ('Issued','Completed') then raise exception 'Issued refunds cannot be cancelled';end if;
 result:=public.refund_request_action_before_lifecycle(p);
 if p->>'action'='complete' and r.status not in ('Issued','Completed') then
 select * into r from public.refund_requests where id=r.id;
 select * into proof from public.documents where id=r.proof_document_id;
 update public.documents set visibility='customer' where id=proof.id;
 token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');path:='/refund/'||token;
 insert into private.refund_links values(r.id,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '90 days');
 update public.notifications set payload=payload||jsonb_build_object('subject','Refund issued — '||(r.confirmation_snapshot->>'job_code'),'text','Your refund of $'||to_char((r.confirmation_snapshot->>'amount')::numeric,'FM999999990.00')||' was issued manually via '||r.method||'. Reference: '||r.reference||'. Open the secure link to view your payment proof and confirm receipt. If you do not respond within 5 calendar days, this record will be marked Completed automatically.','action_path',path,'refund_id',r.id,'proof_id',proof.id)
 where dedupe_key='manual-refund-completed:'||r.id||':'||r.amount and status in ('Pending Integration','Queued');
 end if;
 end if;
 perform private.rbac_log('refund.lifecycle.'||(p->>'action'),r.id,jsonb_build_object('job_id',r.job_id));return coalesce(result,jsonb_build_object('job_id',r.job_id,'ok',true));
end$$;
create function private.complete_refund(p_id uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$begin
 update public.refund_requests set status='Completed',completed_at=now(),acknowledged_at=case when p_reason='Customer confirmed' then now() else acknowledged_at end,completion_reason=p_reason where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' and status='Issued';
 if found then insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values('10000000-0000-0000-0000-000000000002',auth.uid(),'refund_requests',p_id,'Completed',jsonb_build_object('reason',p_reason));end if;
end$$;
create function public.public_refund(p_token text,p_ack boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$declare r public.refund_requests;begin
 select rr.* into r from public.refund_requests rr join private.refund_links l on l.refund_id=rr.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now() and rr.unit_id='10000000-0000-0000-0000-000000000002' and rr.status in ('Issued','Completed') for update of rr;
 if r.id is null then raise exception 'Refund link unavailable';end if;
 if p_ack and r.status='Issued' then perform private.complete_refund(r.id,case when now()>=r.acknowledgment_deadline then 'No response within 5 days' else 'Customer confirmed' end);select * into r from public.refund_requests where id=r.id;end if;
 return jsonb_build_object('status',r.status,'amount',r.amount,'issued_amount',coalesce((r.confirmation_snapshot->>'amount')::numeric,r.amount),'method',r.method,'reference',r.reference,'job_code',r.confirmation_snapshot->>'job_code','issued_at',r.issued_at,'deadline',r.acknowledgment_deadline,'completed_at',r.completed_at,'completion_reason',r.completion_reason,'proof_available',r.proof_document_id is not null);
end$$;
create function public.refund_proof_access(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$declare r public.refund_requests;d public.documents;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 perform public.public_refund(p_token,false);
 select rr.* into r from public.refund_requests rr join private.refund_links l on l.refund_id=rr.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 select * into d from public.documents where id=r.proof_document_id and refund_request_id=r.id and unit_id=r.unit_id and job_id=r.job_id and storage_status='stored';
 if d.id is null then raise exception 'Proof unavailable';end if;return jsonb_build_object('file_name',d.file_name,'mime_type',d.mime_type,'bucket',d.storage_bucket,'path',d.storage_path);
end$$;
create function private.reconcile_issued_refunds() returns void language plpgsql security definer set search_path='' as $$declare id uuid;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 for id in select r.id from public.refund_requests r where r.unit_id='10000000-0000-0000-0000-000000000002' and r.status='Issued' and r.acknowledgment_deadline<=now() for update skip locked loop perform private.complete_refund(id,'No response within 5 days');end loop;
end$$;
do $$declare d text;begin
 d:=pg_get_functiondef('public.run_scheduled_tasks()'::regprocedure);
 d:=regexp_replace(d,'\mbegin\M','begin perform private.reconcile_issued_refunds();','i');execute d;
end$$;
revoke all on function private.refund_approver(),private.complete_refund(uuid,text),private.reconcile_issued_refunds() from public,anon,authenticated;
revoke all on function public.refund_request_action(jsonb),public.refund_can_approve() from public,anon;
grant execute on function public.refund_request_action(jsonb),public.refund_can_approve() to authenticated;
revoke all on function public.public_refund(text,boolean) from public;grant execute on function public.public_refund(text,boolean) to anon,authenticated,service_role;
revoke all on function public.refund_proof_access(text) from public,anon,authenticated;grant execute on function public.refund_proof_access(text) to service_role;
notify pgrst,'reload schema';
commit;
