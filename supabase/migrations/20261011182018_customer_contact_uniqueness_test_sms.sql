-- Real ToolTag contacts are unique; administrator-created TEST- fixtures are excluded.
create unique index tooltag_customer_email_unique on public.customers(lower(trim(email)))
 where unit_id='10000000-0000-0000-0000-000000000002' and name not like 'TEST-%' and nullif(trim(email),'') is not null;
create unique index tooltag_customer_phone_unique on public.customers(private.get_tagged_phone(phone))
 where unit_id='10000000-0000-0000-0000-000000000002' and name not like 'TEST-%' and private.get_tagged_phone(phone)<>'';
create function private.validate_customer_contacts() returns trigger
 language plpgsql security definer set search_path='' as $$
begin
 if new.unit_id<>'10000000-0000-0000-0000-000000000002' then return new;end if;
 if new.name like 'TEST-%' then
  -- Only staff may create fixtures; public callers cannot self-classify as TEST.
  perform private.require_admin(new.unit_id);
  return new;
 end if;
 if exists(select 1 from public.customers c where c.unit_id=new.unit_id and c.id is distinct from new.id and c.name not like 'TEST-%' and nullif(trim(new.email),'') is not null and lower(trim(c.email))=lower(trim(new.email))) then
  raise exception 'This email already belongs to another customer. Open the existing customer profile.' using errcode='23505',constraint='tooltag_customer_email_unique';
 end if;
 if exists(select 1 from public.customers c where c.unit_id=new.unit_id and c.id is distinct from new.id and c.name not like 'TEST-%' and private.get_tagged_phone(new.phone)<>'' and private.get_tagged_phone(c.phone)=private.get_tagged_phone(new.phone)) then
  raise exception 'This phone number already belongs to another customer. Open the existing customer profile.' using errcode='23505',constraint='tooltag_customer_phone_unique';
 end if;
 return new;
end $$;
revoke all on function private.validate_customer_contacts() from public;
create trigger customer_contact_uniqueness before insert or update of name,email,phone,unit_id on public.customers for each row execute function private.validate_customer_contacts();
CREATE OR REPLACE FUNCTION public.save_customer(p jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare u uuid:=(p->>'unit_id')::uuid; cid uuid:=nullif(p->>'id','')::uuid;
begin
 perform private.require_admin(u);
 if u<>'10000000-0000-0000-0000-000000000002' then
 if exists(select 1 from public.customers where unit_id=u and id is distinct from cid and
 ((nullif(trim(p->>'email'),'') is not null and lower(email)=lower(trim(p->>'email'))) or
 (nullif(regexp_replace(p->>'phone','\D','','g'),'') is not null and regexp_replace(phone,'\D','','g')=regexp_replace(p->>'phone','\D','','g')))) then raise exception 'A customer with this email or phone exists. Open their profile before creating another.'; end if;
 end if;
 if cid is null then
 insert into public.customers(unit_id,name,phone,email,address,company_name,company_phone,company_email,company_address)
 values(u,trim(p->>'name'),trim(p->>'phone'),lower(trim(p->>'email')),p->>'address',p->>'company_name',p->>'company_phone',p->>'company_email',p->>'company_address') returning id into cid;
 else update public.customers set name=p->>'name',phone=p->>'phone',email=lower(p->>'email'),address=p->>'address',company_name=p->>'company_name',company_phone=p->>'company_phone',company_email=p->>'company_email',company_address=p->>'company_address',updated_at=now() where id=cid and unit_id=u;
 if not found then raise exception 'Customer not found'; end if;
 end if;
 return cid;
end $$;


create or replace function private.enqueue_sms() returns trigger language plpgsql security definer set search_path='' as $$
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
 why:=case when not coalesce(s.enabled,false) or s.activated_at is null or new.created_at<s.activated_at then 'DISABLED' when fid is null then 'NO_CUSTOMER' when not coalesce(c.granted,false) then 'NO_OPT_IN' when c.phone !~ '^\+[1-9][0-9]{7,14}$' then 'NO_VALID_PHONE' when exists(select 1 from public.customers where id=c.customer_id and name like 'TEST-%') and c.phone is distinct from nullif(s.test_phone,'') then 'TEST_RECIPIENT_MISMATCH' else null end;
 expiry:=greatest(new.created_at,coalesce(new.due_at,new.created_at))+case when ev in ('PICKUP_ARRIVED','RETURN_ARRIVED') then interval '5 minutes' when ev like '%DRIVER_NEARBY' then interval '30 minutes' when ev like '%EN_ROUTE' or ev like '%ROUTE_DEPARTED' then interval '6 hours' else interval '24 hours' end;
 insert into private.sms_deliveries(notification_id,flow_id,status,reason,expires_at) values(new.id,fid,case when why is null then 'Pending' else 'Skipped' end,why,expiry) on conflict do nothing;
 return new;
end $$;
create or replace function public.claim_sms() returns jsonb language plpgsql security definer set search_path='' as $$
declare d private.sms_deliveries;n public.notifications;c private.sms_consents;s private.sms_settings;why text;begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Worker credentials required';end if;
 select * into s from private.sms_settings where unit_id='10000000-0000-0000-0000-000000000002';
 -- Never replay an ambiguous send after a worker crash. SNS direct SMS has no idempotency token.
 update private.sms_deliveries set status='Unknown',reason='WORKER_INTERRUPTED',finished_at=now() where status='Sending' and claimed_at<now()-interval '2 minutes';
 for d in select x.* from private.sms_deliveries x join public.notifications nn on nn.id=x.notification_id where x.status='Pending' and coalesce(nn.due_at,nn.created_at)<=now() order by x.created_at for update of x skip locked limit 30 loop
  select * into n from public.notifications where id=d.notification_id;
  select * into c from private.sms_consents where flow_id=d.flow_id;
  why:=case when not s.enabled then 'DISABLED' when d.created_at<s.activated_at then 'BEFORE_ACTIVATION' when d.expires_at<=now() then 'EXPIRED' when not coalesce(c.granted,false) then 'NO_OPT_IN' when c.phone !~ '^\+[1-9][0-9]{7,14}$' then 'NO_VALID_PHONE' when exists(select 1 from public.customers where id=c.customer_id and name like 'TEST-%') and c.phone is distinct from nullif(s.test_phone,'') then 'TEST_RECIPIENT_MISMATCH' else null end;
  if why is not null then update private.sms_deliveries set status='Skipped',reason=why,finished_at=now() where notification_id=d.notification_id;continue;end if;
  update private.sms_deliveries set status='Sending',phone=c.phone,claim=gen_random_uuid(),claimed_at=now() where notification_id=d.notification_id returning * into d;
  return jsonb_build_object('id',n.id,'event',n.event,'phone',c.phone,'payload',n.payload,'claim',d.claim,'test_customer',exists(select 1 from public.customers where id=c.customer_id and name like 'TEST-%'));
 end loop;
 return null;
end $$;
