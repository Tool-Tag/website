begin;
-- Private request-level state exists before a Customer/Quote and is never exposed publicly.
create table private.request_sms_cost_usage (
 notification_id uuid primary key,request_id uuid not null,reference text not null,
 provider_id text not null unique,unit_cost numeric(12,8) not null check(unit_cost>=0),
 accepted_at timestamptz not null, transferred_at timestamptz
);
alter table private.request_sms_cost_usage enable row level security;
revoke all on private.request_sms_cost_usage from public,anon,authenticated;
create function private.request_sms_consent(n public.notifications) returns private.sms_consents
language plpgsql stable security definer set search_path='' as $$
declare c private.sms_consents;r private.get_tagged_receipts;fid uuid;details jsonb;begin
 fid:=private.notification_sms_flow(n);
 select * into c from private.sms_consents where flow_id=fid;
 if c.flow_id is not null then return c;end if;
 if n.unit_id<>'10000000-0000-0000-0000-000000000002' or n.event not in ('GET_TAGGED_RECEIVED','REQUEST_REJECTED') then return c;end if;
 select * into r from private.get_tagged_receipts where id=n.entity_id;
 details:=r.details->'sms';
 c.unit_id:=n.unit_id;c.customer_id:=r.customer_id;c.phone:=coalesce(details->>'phone','');c.granted_at:=r.created_at;
 c.granted:=details->'granted'='true'::jsonb and details->'policy_accepted'='true'::jsonb
 and c.phone ~ '^\+[1-9][0-9]{7,14}$' and coalesce(details->>'privacy_url','') ~ '^https://'
 and coalesce(details->>'terms_url','') ~ '^https://' and nullif(trim(details->>'disclosure'),'') is not null
 and not exists(select 1 from private.sms_consent_events e where e.phone=c.phone and not e.granted and e.created_at>=r.created_at);
 return c;
end$$;
create function private.sms_notification_is_test(n public.notifications) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.customers c join public.commercial_flows f on f.customer_id=c.id where f.id=private.notification_sms_flow(n) and c.name like 'TEST-%')
 or exists(select 1 from private.get_tagged_receipts r where r.id=n.entity_id and n.event in ('GET_TAGGED_RECEIVED','REQUEST_REJECTED') and r.details->'contact'->>'name' like 'TEST-%')
$$;
revoke all on function private.request_sms_consent(public.notifications),private.sms_notification_is_test(public.notifications) from public,anon,authenticated;
do $$declare d text;begin
 d:=pg_get_functiondef('private.enqueue_sms()'::regprocedure);
 if position('select * into c from private.sms_consents where flow_id=fid;' in d)=0 then raise exception 'Unexpected SMS enqueue consent lookup';end if;
 d:=replace(d,'select * into c from private.sms_consents where flow_id=fid;','c:=private.request_sms_consent(new);');
 d:=replace(d,'when fid is null then ''NO_CUSTOMER''','when fid is null and new.event not in (''GET_TAGGED_RECEIVED'',''REQUEST_REJECTED'') then ''NO_CUSTOMER''');
 d:=replace(d,'exists(select 1 from public.customers where id=c.customer_id and name like ''TEST-%'')','private.sms_notification_is_test(new)');
 execute d;
 d:=pg_get_functiondef('public.claim_sms()'::regprocedure);
 if position('select * into c from private.sms_consents where flow_id=d.flow_id;' in d)=0 then raise exception 'Unexpected SMS claim consent lookup';end if;
 d:=replace(d,'select * into c from private.sms_consents where flow_id=d.flow_id;','c:=private.request_sms_consent(n);');
 d:=replace(d,'exists(select 1 from public.customers where id=c.customer_id and name like ''TEST-%'')','private.sms_notification_is_test(n)');
 d:=replace(d,'set status=''Sending'',phone=c.phone','set status=''Sending'',flow_id=coalesce(d.flow_id,c.flow_id),phone=c.phone');
 execute d;
end$$;
-- Preserve the tariff when AWS is attempted. Rejections never create cost usage.
create function private.prepare_request_sms_cost() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='Sending' and old.status<>'Sending' and new.flow_id is null and exists(select 1 from public.notifications n where n.id=new.notification_id and n.event in ('GET_TAGGED_RECEIVED','REQUEST_REJECTED')) then
 select sms_unit_cost into new.costing_rate from public.unit_settings where unit_id='10000000-0000-0000-0000-000000000002';
 end if;return new;
end$$;
create trigger request_sms_cost_prepare before update of status on private.sms_deliveries for each row execute function private.prepare_request_sms_cost();
create function private.record_request_sms_cost() returns trigger language plpgsql security definer set search_path='' as $$
declare n public.notifications;r private.get_tagged_receipts;begin
 if new.flow_id is not null or new.costing_rate is null or coalesce(new.provider_id,'')='' then return new;end if;
 select * into n from public.notifications where id=new.notification_id;
 if n.event not in ('GET_TAGGED_RECEIVED','REQUEST_REJECTED') then return new;end if;
 select * into r from private.get_tagged_receipts where id=n.entity_id;
 if r.id is not null then insert into private.request_sms_cost_usage(notification_id,request_id,reference,provider_id,unit_cost,accepted_at)
 values(new.notification_id,r.id,r.reference,new.provider_id,new.costing_rate,coalesce(new.finished_at,now())) on conflict do nothing;end if;
 return new;
end$$;
create trigger request_sms_cost_record after update of status,provider_id on private.sms_deliveries for each row execute function private.record_request_sms_cost();
-- On conversion, transfer accepted Request sends into the existing Quote/Job cost ledger exactly once.
create function private.transfer_request_sms_cost() returns trigger language plpgsql security definer set search_path='' as $$
declare q public.quotes;begin
 if new.quote_id is null or (tg_op='UPDATE' and new.quote_id is not distinct from old.quote_id) then return new;end if;
 select * into q from public.quotes where id=new.quote_id;
 update private.sms_deliveries d set flow_id=q.flow_id,costing_quote_id=q.id,costing_quote_code=q.code,status=d.status
 where d.notification_id in (select n.id from public.notifications n where n.entity_id=new.id and n.event in ('GET_TAGGED_RECEIVED','REQUEST_REJECTED')) and d.flow_id is null;
 update private.request_sms_cost_usage set transferred_at=now() where request_id=new.id and transferred_at is null;
 return new;
end$$;
create trigger request_sms_cost_transfer after insert or update of quote_id on private.get_tagged_receipts for each row execute function private.transfer_request_sms_cost();
revoke all on function private.prepare_request_sms_cost(),private.record_request_sms_cost(),private.transfer_request_sms_cost() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
