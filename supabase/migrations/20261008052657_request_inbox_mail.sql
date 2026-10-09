-- Private bearer links reveal progress only, never act as Quote acceptance links.
create table private.request_status_links (
 request_id uuid primary key references private.get_tagged_receipts(id),
 token text not null unique, token_hash text not null unique
);
alter table private.request_status_links enable row level security;
revoke all on private.request_status_links from public,anon,authenticated,service_role;
-- Only NEW intake receipts enqueue mail. Historical requests remain untouched.
create function private.notify_get_tagged_request() returns trigger language plpgsql security definer set search_path='' as $$
declare status_token text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
begin
 insert into private.request_status_links(request_id,token,token_hash) values(new.id,status_token,encode(sha256(convert_to(status_token,'UTF8')),'hex'));
 insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
 values('10000000-0000-0000-0000-000000000002','GET_TAGGED_REQUEST',new.id,'get-tagged-request:'||new.id,
 jsonb_build_object('template','get_tagged_request','live_eligible',true,'reference',new.reference,'contact',new.details->'contact','service',new.details->'service','items',new.details->'items','notes',new.details->>'notes'))
 on conflict(dedupe_key) do nothing;
 insert into public.notifications(unit_id,event,entity_id,recipient,dedupe_key,payload)
 values('10000000-0000-0000-0000-000000000002','GET_TAGGED_RECEIVED',new.id,new.details->'contact'->>'email','get-tagged-received:'||new.id,
 jsonb_build_object('template','get_tagged_received','live_eligible',true,'reference',new.reference,'name',new.details->'contact'->>'name')) on conflict(dedupe_key) do nothing;
 return new;
end $$;
revoke all on function private.notify_get_tagged_request() from public,anon,authenticated;
create trigger get_tagged_request_mail after insert on private.get_tagged_receipts for each row execute function private.notify_get_tagged_request();

create function public.get_tagged_pending_count() returns integer language plpgsql security definer set search_path='' as $$
begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 return (select count(*)::integer from private.get_tagged_receipts r where r.request_status='Pending');
end $$;
revoke all on function public.get_tagged_pending_count() from public,anon;
grant execute on function public.get_tagged_pending_count() to authenticated;

-- Separate claims use the existing notification log but cannot replay customer mail.
create function public.claim_get_tagged_mail(p_id uuid,p_recipient text,p_mode text) returns jsonb language plpgsql security definer set search_path='' as $$
declare n public.notifications;
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Worker credentials required' using errcode='42501'; end if;
 if p_mode not in ('live','test-delivery') or p_mode is null or p_recipient is null or p_recipient !~ '^[^[:space:]<>@,;]+@[^[:space:]<>@,;]+[.][^[:space:]<>@,;]+$' then raise exception 'Invalid mail configuration'; end if;
 select * into n from public.notifications x where x.event in ('GET_TAGGED_REQUEST','GET_TAGGED_RECEIVED') and x.unit_id='10000000-0000-0000-0000-000000000002'
 and (p_id is null or x.entity_id=p_id) and x.status='Pending Integration' and x.mail_claim is null
 and ((p_mode='live' and x.delivery_phase='production') or (p_mode='test-delivery' and x.delivery_phase='test'))
 and (p_mode='live' or x.event='GET_TAGGED_REQUEST' or lower(x.recipient)=lower(p_recipient))
 order by x.created_at,x.event desc for update skip locked limit 1;
 if not found then return null; end if;
 update public.notifications set status='Queued',recipient=case when event='GET_TAGGED_REQUEST' then p_recipient else recipient end,mail_claim=gen_random_uuid(),mail_attempted_at=now() where id=n.id returning * into n;
 return to_jsonb(n)||jsonb_build_object('status_token',(select token from private.request_status_links where request_id=n.entity_id));
end $$;
create function public.finish_get_tagged_mail(p_id uuid,p_claim uuid,p_provider_id text,p_error text) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_setting('request.jwt.claim.role',true),'')<>'service_role' then raise exception 'Worker credentials required' using errcode='42501'; end if;
 if nullif(p_provider_id,'') is null and p_error is null then raise exception 'Delivery result required'; end if;
 update public.notifications set status=case when nullif(p_provider_id,'') is not null then 'Sent' else 'Failed' end,
 provider_id=p_provider_id,mail_error=p_error,sent_at=case when nullif(p_provider_id,'') is not null then now() else null end
 where id=p_id and event in ('GET_TAGGED_REQUEST','GET_TAGGED_RECEIVED') and unit_id='10000000-0000-0000-0000-000000000002' and status='Queued' and mail_claim=p_claim;
 return found;
end $$;
revoke all on function public.claim_get_tagged_mail(uuid,text,text),public.finish_get_tagged_mail(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.claim_get_tagged_mail(uuid,text,text),public.finish_get_tagged_mail(uuid,uuid,text,text) to service_role;
notify pgrst,'reload schema';

create function public.public_request_status(p_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.get_tagged_receipts; q public.quotes; j public.jobs; stage text; job_token text; stamp timestamptz; steps jsonb:=jsonb_build_array('Request received','In review','Preparing quote','Quote sent','In Process','Engraving','Final Details','Completed');
begin
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then return null; end if;
 select x.* into r from private.get_tagged_receipts x join private.request_status_links l on l.request_id=x.id where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 if not found then return null; end if;
 select * into q from public.quotes where flow_id=(select flow_id from public.quotes where id=r.quote_id) order by revision desc limit 1;
 stage:='In review';stamp:=r.created_at;
 if q.id is not null then stage:='Preparing quote';stamp:=coalesce(q.intake_reviewed_at,q.created_at);end if;
 if q.sent_at is not null then stage:='Quote sent';stamp:=q.sent_at;end if;
 if r.request_status='Rejected' then stage:='Contact ToolTag';stamp:=coalesce(r.rejected_at,r.created_at);end if;
 if q.status in ('Declined','Expired') then stage:='Contact ToolTag';end if;
 select * into j from public.jobs where flow_id=q.flow_id;
 if j.id is not null then
  select token into job_token from private.job_status_links where job_id=j.id;
  stage:=case when j.status='Cancelled' then 'Contact ToolTag' when to_jsonb(j)->>'work_stage'='Closed' then 'Completed' else coalesce(to_jsonb(j)->>'customer_stage','In Process') end;stamp:=j.updated_at;
 end if;
 return jsonb_build_object('code',r.reference,'stage',stage,'steps',steps,'updated_at',stamp,'request_tracking',true,'job_status_token',job_token);
end $$;
revoke all on function public.public_request_status(text) from public;
grant execute on function public.public_request_status(text) to anon,authenticated;
notify pgrst,'reload schema';
