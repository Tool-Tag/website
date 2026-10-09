
alter table public.jobs
  drop constraint if exists jobs_customer_stage_check;

alter table public.jobs
  add constraint jobs_customer_stage_check
  check (customer_stage in ('In Process','Engraving','Final Details','Completed'));

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
    'steps',jsonb_build_array(
      'In Process',
      'Engraving',
      'Final Details',
      'Completed'
    )
  );
end $$;

create or replace function public.set_job_customer_stage(p_job uuid,p_stage text)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  stage_order integer;
  current_order integer;
begin
  select * into j
  from public.jobs
  where id=p_job
  for update;

  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  stage_order:=case p_stage
    when 'In Process' then 1
    when 'Engraving' then 2
    when 'Final Details' then 3
    when 'Completed' then 4
    else null
  end;

  current_order:=case j.customer_stage
    when 'In Process' then 1
    when 'Engraving' then 2
    when 'Final Details' then 3
    when 'Completed' then 4
    else 0
  end;

  if stage_order is null then
    raise exception 'Invalid customer stage';
  end if;

  if stage_order<current_order then
    raise exception 'Customer stage cannot move backward';
  end if;

  update public.jobs
  set customer_stage=p_stage,
      updated_at=now()
  where id=j.id;

  return p_stage;
end $$;

revoke all on function public.set_job_customer_stage(uuid,text)
from public,anon;
grant execute on function public.set_job_customer_stage(uuid,text)
to authenticated;

create or replace function private.notify_customer_stage_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  token_value text;
  recipient_value text;
  subject_value text;
  text_value text;
begin
  if old.customer_stage is not distinct from new.customer_stage then
    return new;
  end if;

  -- In Process gets the original Job Status email.
  -- Completed gets the dedicated Accept Delivery email.
  if new.customer_stage not in ('Engraving','Final Details') then
    return new;
  end if;

  token_value:=private.ensure_job_status_link(new.id);

  select coalesce(
    d.customer_recipient_email,
    a.accepted_email,
    a.commercial_snapshot->>'customer_email'
  )
  into recipient_value
  from public.agreements a
  left join public.accepted_documents d on d.agreement_id=a.id
  where a.job_id=new.id
  order by a.accepted_at desc
  limit 1;

  if nullif(trim(recipient_value),'') is null then
    return new;
  end if;

  if new.customer_stage='Engraving' then
    subject_value:='ToolTag Job Update — Engraving — '||new.code;
    text_value:='Your ToolTag Job has moved to the engraving stage. Use your private Job Status link to follow the progress.';
  else
    subject_value:='ToolTag Job Update — Final Details — '||new.code;
    text_value:='Your ToolTag Job is in final details and quality review. Use your private Job Status link to follow the progress.';
  end if;

  insert into public.notifications(
    unit_id,event,entity_id,recipient,dedupe_key,payload
  )
  values(
    new.unit_id,
    'JOB_STATUS_UPDATE',
    new.id,
    recipient_value,
    'job-status-stage:'||new.id||':'||lower(replace(new.customer_stage,' ','-')),
    jsonb_build_object(
      'template','notification',
      'subject',subject_value,
      'text',text_value,
      'action_path','/status/'||token_value,
      'live_eligible',true
    )
  )
  on conflict do nothing;

  return new;
end $$;

drop trigger if exists notify_customer_stage_change on public.jobs;
create trigger notify_customer_stage_change
after update of customer_stage on public.jobs
for each row
execute function private.notify_customer_stage_change();

revoke all on function private.notify_customer_stage_change()
from public,anon,authenticated,service_role;

create or replace function public.add_document(p jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  u uuid:=(p->>'unit_id')::uuid;
  did uuid;
  tx public.transactions;
  jid uuid:=nullif(p->>'job_id','')::uuid;
begin
  perform private.require_admin(u);

  if nullif(trim(p->>'drive_file_id'),'') is null then
    raise exception 'A real Google Drive file ID is required; uploads are not connected yet';
  end if;

  if p->>'drive_file_id' !~ '^[a-zA-Z0-9_-]{10,}$' then
    raise exception 'Invalid Drive file ID';
  end if;

  insert into public.documents(
    unit_id,type,drive_file_id,file_name,customer_id,job_id,
    transaction_id,status,uploaded_by
  )
  values(
    u,
    p->>'type',
    p->>'drive_file_id',
    p->>'file_name',
    nullif(p->>'customer_id','')::uuid,
    jid,
    nullif(p->>'transaction_id','')::uuid,
    'Available',
    auth.uid()
  )
  returning id into did;

  if p->>'type'='Completed Evidence'
     and jid is not null
  then
    update public.jobs
    set customer_stage='Final Details',
        updated_at=now()
    where id=jid
      and unit_id=u
      and customer_stage='Engraving';
  end if;

  select * into tx
  from public.transactions
  where id=nullif(p->>'transaction_id','')::uuid;

  update public.monthly_closes
  set status=case
    when status='Reclose Required' then status
    else 'Documentation Updated'
  end
  where unit_id=u
    and month=date_trunc('month',tx.transaction_date)::date
    and status<>'Superseded';

  return did;
end $$;
