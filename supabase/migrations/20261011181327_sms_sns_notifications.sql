-- Additive, opt-in SMS channel; existing email queue and Agreement text stay unchanged.
create table private.sms_settings (
 unit_id uuid primary key references public.business_units(id), enabled boolean not null default false,
 activated_at timestamptz, region text not null default '', origination_number text not null default '',
 test_phone text not null default '', encrypted_credentials text, updated_at timestamptz not null default now(),
 last_test_at timestamptz, last_test_result text,
 check (region='' or region ~ '^[a-z]{2}(-[a-z]+)+-[0-9]+$'),
 check (origination_number='' or origination_number ~ '^\+[1-9][0-9]{7,14}$'),
 check (test_phone='' or test_phone ~ '^\+[1-9][0-9]{7,14}$'),
 check (encrypted_credentials is null or encrypted_credentials ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
);
insert into private.sms_settings(unit_id) values('10000000-0000-0000-0000-000000000002');
create table private.sms_consents (
 flow_id uuid primary key references public.commercial_flows(id) on delete cascade,
 unit_id uuid not null references public.business_units(id), customer_id uuid not null references public.customers(id),
 phone text not null default '', granted boolean not null default false,
 disclosure_version text not null default 'tooltag-transactional-sms-v1', updated_at timestamptz not null default now(),
 check (not granted or phone ~ '^\+[1-9][0-9]{7,14}$')
);
create table private.sms_consent_events (
 id uuid primary key default gen_random_uuid(), flow_id uuid not null references public.commercial_flows(id) on delete cascade,
 phone text not null, granted boolean not null, source text not null,
 disclosure text not null, created_at timestamptz not null default now()
);
create table private.sms_deliveries (
 notification_id uuid primary key references public.notifications(id) on delete cascade,
 flow_id uuid references public.commercial_flows(id) on delete cascade,
 status text not null check(status in ('Pending','Sending','Sent','Failed','Unknown','Skipped')),
 reason text, phone text, claim uuid, claimed_at timestamptz, provider_id text,
 expires_at timestamptz not null, created_at timestamptz not null default now(), finished_at timestamptz
);
create index sms_pending on private.sms_deliveries(created_at) where status='Pending';
alter table private.sms_settings enable row level security;
alter table private.sms_consents enable row level security;
alter table private.sms_consent_events enable row level security;
alter table private.sms_deliveries enable row level security;
revoke all on private.sms_settings,private.sms_consents,private.sms_consent_events,private.sms_deliveries from public,anon,authenticated;

create function private.sms_flow(p_token text,p_scope text) returns public.commercial_flows
language plpgsql security definer set search_path='' as $$
declare f public.commercial_flows; j public.jobs;
begin
 if p_scope='quote' then
  select x.* into f from public.commercial_flows x join public.quotes q on q.flow_id=x.id join private.public_links l on l.quote_id=q.id
  where l.token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex') and l.expires_at>now();
 elsif p_scope='status' then
  j:=private.audit_status_job(p_token); select * into f from public.commercial_flows where id=j.flow_id;
 end if;
 if f.id is null or f.unit_id<>'10000000-0000-0000-0000-000000000002' then raise exception 'SMS preference link unavailable';end if;
 return f;
end $$;
revoke all on function private.sms_flow(text,text) from public;
create function public.sms_consent_state(p_token text,p_scope text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare f public.commercial_flows;c private.sms_consents;
begin f:=private.sms_flow(p_token,p_scope);select * into c from private.sms_consents where flow_id=f.id;
 return jsonb_build_object('phone',coalesce(c.phone,''),'granted',coalesce(c.granted,false));end $$;
create function public.set_sms_consent(p_token text,p_scope text,p_phone text,p_granted boolean) returns void
language plpgsql security definer set search_path='' as $$
declare f public.commercial_flows;prior text;disclosure text:='I agree to receive automated transactional SMS from ToolTag about this quote/job, scheduling, driver arrival, confirmations and payments at the number provided. Consent is optional and is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply STOP to opt out, HELP for help, or manage preferences in tracking.';
begin
 f:=private.sms_flow(p_token,p_scope);
 if p_granted and (p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$') then raise exception 'Enter a mobile number in international format, such as +18015550100';end if;
 select phone into prior from private.sms_consents where flow_id=f.id for update;
 if not p_granted and coalesce(prior,'')<>'' then
  -- A website revocation applies to all ToolTag consent records for the same number.
  update private.sms_consents set granted=false,updated_at=now() where phone=prior and unit_id=f.unit_id;
  insert into private.sms_consent_events(flow_id,phone,granted,source,disclosure) select flow_id,phone,false,p_scope,disclosure from private.sms_consents where phone=prior and unit_id=f.unit_id;
 end if;
 insert into private.sms_consents(flow_id,unit_id,customer_id,phone,granted)
 values(f.id,f.unit_id,f.customer_id,case when p_granted then p_phone else coalesce(prior,'') end,p_granted)
 on conflict(flow_id) do update set phone=excluded.phone,granted=excluded.granted,updated_at=now();
 insert into private.sms_consent_events(flow_id,phone,granted,source,disclosure)
 values(f.id,case when p_granted then p_phone else coalesce(prior,'') end,p_granted,p_scope,disclosure);
end $$;
revoke all on function public.sms_consent_state(text,text),public.set_sms_consent(text,text,text,boolean) from public;
grant execute on function public.sms_consent_state(text,text),public.set_sms_consent(text,text,text,boolean) to anon,authenticated;

create function public.sms_settings_status() returns jsonb language plpgsql security definer set search_path='' as $$
declare s private.sms_settings;logs jsonb;begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');select * into s from private.sms_settings where unit_id='10000000-0000-0000-0000-000000000002';
 select coalesce(jsonb_agg(x),'[]'::jsonb) into logs from (select d.status,d.reason,d.created_at,d.provider_id,n.event from private.sms_deliveries d join public.notifications n on n.id=d.notification_id order by d.created_at desc limit 20) x;
 return jsonb_build_object('enabled',s.enabled,'region',s.region,'origination_number',s.origination_number,'test_phone',s.test_phone,'credentials_saved',s.encrypted_credentials is not null,'activated_at',s.activated_at,'last_test_at',s.last_test_at,'last_test_result',s.last_test_result,'logs',logs);
end $$;
create function public.save_sms_settings(p_config jsonb,p_encrypted text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 update private.sms_settings set enabled=coalesce((p_config->>'enabled')::boolean,false),
 activated_at=case when coalesce((p_config->>'enabled')::boolean,false) and not enabled then now() else activated_at end,
 region=coalesce(p_config->>'region',''),origination_number=coalesce(p_config->>'origination_number',''),test_phone=coalesce(p_config->>'test_phone',''),
 encrypted_credentials=coalesce(p_encrypted,encrypted_credentials),updated_at=now()
 where unit_id='10000000-0000-0000-0000-000000000002';
end $$;
create function public.reserve_sms_test() returns boolean language plpgsql security definer set search_path='' as $$
declare changed integer;begin
 perform private.require_admin('10000000-0000-0000-0000-000000000002');
 update private.sms_settings set last_test_at=now(),last_test_result='Pending' where unit_id='10000000-0000-0000-0000-000000000002' and (last_test_at is null or last_test_at<now()-interval '90 seconds');
 get diagnostics changed=row_count;return changed=1;
end $$;
revoke all on function public.sms_settings_status(),public.save_sms_settings(jsonb,text),public.reserve_sms_test() from public;
grant execute on function public.sms_settings_status(),public.save_sms_settings(jsonb,text),public.reserve_sms_test() to authenticated;
create function public.sms_runtime_config() returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 return (select to_jsonb(s) from private.sms_settings s where unit_id='10000000-0000-0000-0000-000000000002');
end $$;
create function public.finish_sms_test(p_result text) returns void language plpgsql security definer set search_path='' as $$
begin if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 update private.sms_settings set last_test_result=left(p_result,100) where unit_id='10000000-0000-0000-0000-000000000002';end $$;
revoke all on function public.sms_runtime_config(),public.finish_sms_test(text) from public,anon,authenticated;
grant execute on function public.sms_runtime_config(),public.finish_sms_test(text) to service_role;

create function private.enqueue_sms() returns trigger language plpgsql security definer set search_path='' as $$
declare ev text;fid uuid;c private.sms_consents;s private.sms_settings;why text;expiry timestamptz;begin
 if new.unit_id<>'10000000-0000-0000-0000-000000000002' then return new;end if;
 ev:=upper(regexp_replace(new.event,'[^a-zA-Z0-9]+','_','g'));
 if ev not in ('PICKUP_ROUTE_DEPARTED','RETURN_ROUTE_DEPARTED','PICKUP_DRIVER_NEARBY','RETURN_DRIVER_NEARBY','PICKUP_ARRIVED','RETURN_ARRIVED','PICKUP_EN_ROUTE','RETURN_EN_ROUTE','PICKUP_SCHEDULED','RETURN_SCHEDULED','PICKUP_RESCHEDULED','RETURN_RESCHEDULED','PICKUP_MISSED','RETURN_MISSED','PAYMENT_DUE','PAYMENT_CUTOFF_REMINDER','PICKUP_FEE_REQUIRED','AGREEMENT_ACCEPTED_COPY','JOB_CONFIRMED','JOB_STATUS_UPDATE','JOB_READY','COMPLETION_ACKNOWLEDGMENT','COMPLETION_REMINDER','PAYMENT_RECEIPT','FINAL_PAID_RECEIPT','QUOTE_SENT','QUOTE_EXPIRATION_REMINDER','DRIVER_UNAVAILABLE','ROUTE_INTERRUPTED','JOB_STATUS_LINK','DELIVERY_IN_PROGRESS','SHOP_PICKUP') then return new;end if;
 select flow_id into fid from public.jobs where id=new.entity_id;
 if fid is null then select flow_id into fid from public.quotes where id=new.entity_id;end if;
 if fid is null then select j.flow_id into fid from public.jobs j join public.sales x on x.job_id=j.id where x.transaction_id=new.entity_id;end if;
 if fid is null then select j.flow_id into fid from public.jobs j join public.job_receipts x on x.job_id=j.id where x.id=new.entity_id;end if;
 select * into c from private.sms_consents where flow_id=fid;
 select * into s from private.sms_settings where unit_id=new.unit_id;
 why:=case when not coalesce(s.enabled,false) or s.activated_at is null or new.created_at<s.activated_at then 'DISABLED' when fid is null then 'NO_CUSTOMER' when not coalesce(c.granted,false) then 'NO_OPT_IN' when c.phone !~ '^\+[1-9][0-9]{7,14}$' then 'NO_VALID_PHONE' when exists(select 1 from public.customers where id=c.customer_id and name like 'TEST-%') then 'TEST_CUSTOMER' else null end;
 expiry:=greatest(new.created_at,coalesce(new.due_at,new.created_at))+case when ev in ('PICKUP_ARRIVED','RETURN_ARRIVED') then interval '5 minutes' when ev like '%DRIVER_NEARBY' then interval '30 minutes' when ev like '%EN_ROUTE' or ev like '%ROUTE_DEPARTED' then interval '6 hours' else interval '24 hours' end;
 insert into private.sms_deliveries(notification_id,flow_id,status,reason,expires_at) values(new.id,fid,case when why is null then 'Pending' else 'Skipped' end,why,expiry) on conflict do nothing;
 return new;
end $$;
revoke all on function private.enqueue_sms() from public;
create trigger notification_sms_enqueue after insert on public.notifications for each row execute function private.enqueue_sms();

create function public.claim_sms() returns jsonb language plpgsql security definer set search_path='' as $$
declare d private.sms_deliveries;n public.notifications;c private.sms_consents;s private.sms_settings;why text;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 select * into s from private.sms_settings where unit_id='10000000-0000-0000-0000-000000000002';
 -- Never replay an ambiguous send after a worker crash. SNS direct SMS has no idempotency token.
 update private.sms_deliveries set status='Unknown',reason='WORKER_INTERRUPTED',finished_at=now() where status='Sending' and claimed_at<now()-interval '2 minutes';
 for d in select x.* from private.sms_deliveries x join public.notifications nn on nn.id=x.notification_id where x.status='Pending' and coalesce(nn.due_at,nn.created_at)<=now() order by x.created_at for update of x skip locked limit 30 loop
  select * into n from public.notifications where id=d.notification_id;
  select * into c from private.sms_consents where flow_id=d.flow_id;
  why:=case when not s.enabled then 'DISABLED' when d.created_at<s.activated_at then 'BEFORE_ACTIVATION' when d.expires_at<=now() then 'EXPIRED' when not coalesce(c.granted,false) then 'NO_OPT_IN' when c.phone !~ '^\+[1-9][0-9]{7,14}$' then 'NO_VALID_PHONE' when exists(select 1 from public.customers where id=c.customer_id and name like 'TEST-%') then 'TEST_CUSTOMER' else null end;
  if why is not null then update private.sms_deliveries set status='Skipped',reason=why,finished_at=now() where notification_id=d.notification_id;continue;end if;
  update private.sms_deliveries set status='Sending',phone=c.phone,claim=gen_random_uuid(),claimed_at=now() where notification_id=d.notification_id returning * into d;
  return jsonb_build_object('id',n.id,'event',n.event,'phone',c.phone,'payload',n.payload,'claim',d.claim);
 end loop;
 return null;
end $$;
create function public.finish_sms(p_id uuid,p_claim uuid,p_status text,p_provider text default null,p_reason text default null) returns boolean language plpgsql security definer set search_path='' as $$
declare changed integer;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 if p_status not in ('Sent','Failed','Unknown','Skipped') then raise exception 'Invalid SMS result';end if;
 update private.sms_deliveries set status=p_status,provider_id=p_provider,reason=left(p_reason,100),finished_at=now() where notification_id=p_id and claim=p_claim and status in ('Sending','Unknown');
 get diagnostics changed=row_count;return changed=1;
end $$;
revoke all on function public.claim_sms(),public.finish_sms(uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.claim_sms(),public.finish_sms(uuid,uuid,text,text,text) to service_role;
