
update public.unit_settings
set zelle_email='payments@tooltag.martinlab.studio'
where unit_id='10000000-0000-0000-0000-000000000002';

alter table public.jobs
  add column if not exists customer_stage text not null default 'In Process'
  check (customer_stage in ('In Process','Engraving','Completed'));

update public.jobs
set customer_stage='Completed'
where status in ('Ready for Delivery','Delivered – Pending Customer Acceptance','Completed')
  and customer_stage<>'Completed';

create table if not exists private.job_status_links (
  job_id uuid primary key references public.jobs on delete cascade,
  token text not null,
  token_hash text not null unique,
  created_at timestamptz not null default now()
);

revoke all on private.job_status_links from public,anon,authenticated,service_role;

create or replace function private.ensure_job_status_link(p_job uuid)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  token_value text;
begin
  select token into token_value
  from private.job_status_links
  where job_id=p_job;

  if token_value is null then
    token_value:=gen_random_uuid()::text||gen_random_uuid()::text;
    insert into private.job_status_links(job_id,token,token_hash)
    values(
      p_job,
      token_value,
      encode(sha256(convert_to(token_value,'UTF8')),'hex')
    )
    on conflict(job_id) do update set job_id=excluded.job_id
    returning token into token_value;
  end if;

  return token_value;
end $$;

revoke all on function private.ensure_job_status_link(uuid)
from public,anon,authenticated,service_role;

create or replace function private.create_job_status_portal()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  token_value text;
  recipient_value text;
  job_code text;
begin
  token_value:=private.ensure_job_status_link(new.job_id);

  select j.code into job_code
  from public.jobs j
  where j.id=new.job_id;

  select coalesce(d.recipient,new.accepted_email)
  into recipient_value
  from public.quotes q
  left join private.quote_delivery d on d.quote_id=q.id
  where q.id=new.quote_id;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    new.unit_id,
    'JOB_STATUS_LINK',
    new.job_id,
    recipient_value,
    'job-status:'||new.job_id,
    jsonb_build_object(
      'template','notification',
      'subject','Track your ToolTag Job — '||job_code,
      'text','Your ToolTag Job is now active. Use this private link anytime to check its progress.',
      'action_path','/status/'||token_value,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;

drop trigger if exists create_job_status_portal on public.agreements;
create trigger create_job_status_portal
after insert on public.agreements
for each row execute function private.create_job_status_portal();

create or replace function public.public_job_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  customer_name text;
begin
  select x.* into j
  from public.jobs x
  join private.job_status_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  if j.id is null then raise exception 'Status link unavailable'; end if;

  select c.name into customer_name
  from public.commercial_flows f
  join public.customers c on c.id=f.customer_id
  where f.id=j.flow_id;

  return jsonb_build_object(
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'updated_at',j.updated_at,
    'steps',jsonb_build_array('In Process','Engraving','Completed')
  );
end $$;

revoke all on function public.public_job_status(text) from public;
grant execute on function public.public_job_status(text) to anon,authenticated;

create or replace function public.job_customer_status(p_job uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  token_value text;
begin
  select * into j from public.jobs where id=p_job;
  if j.id is null then raise exception 'Job not found'; end if;

  perform private.require_admin(j.unit_id);
  token_value:=private.ensure_job_status_link(j.id);

  return jsonb_build_object(
    'stage',j.customer_stage,
    'path','/status/'||token_value
  );
end $$;

revoke all on function public.job_customer_status(uuid) from public,anon;
grant execute on function public.job_customer_status(uuid) to authenticated;

create or replace function public.set_job_customer_stage(p_job uuid,p_stage text)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
begin
  select * into j from public.jobs where id=p_job for update;
  if j.id is null then raise exception 'Job not found'; end if;

  perform private.require_admin(j.unit_id);

  if p_stage not in ('In Process','Engraving') then
    raise exception 'Customer stage can only be In Process or Engraving here';
  end if;

  if j.customer_stage='Completed' then
    raise exception 'Completed status cannot be moved backward';
  end if;

  if j.customer_stage='Engraving' and p_stage='In Process' then
    raise exception 'Customer stage cannot move backward';
  end if;

  update public.jobs
  set customer_stage=p_stage,updated_at=now()
  where id=j.id;

  return p_stage;
end $$;

revoke all on function public.set_job_customer_stage(uuid,text) from public,anon;
grant execute on function public.set_job_customer_stage(uuid,text) to authenticated;

create or replace function private.sync_customer_stage()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.status in ('Ready for Delivery','Delivered – Pending Customer Acceptance','Completed')
     and old.status is distinct from new.status then
    new.customer_stage:='Completed';
  end if;
  return new;
end $$;

drop trigger if exists sync_customer_stage on public.jobs;
create trigger sync_customer_stage
before update of status on public.jobs
for each row execute function private.sync_customer_stage();

revoke all on function private.create_job_status_portal(),
  private.sync_customer_stage()
from public,anon,authenticated,service_role;
