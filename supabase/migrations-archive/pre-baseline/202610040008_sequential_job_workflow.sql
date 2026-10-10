alter table public.jobs
  add column if not exists work_stage text not null default 'Not Started'
  check (work_stage in ('Not Started','Receiving Evidence','Preparing','Final Evidence','Awaiting Delivery Acceptance','Payment','Payment Verification','Closed'));

update public.jobs
set work_stage=case
  when status='Authorized' then 'Not Started'
  when status='Receiving Documentation' then 'Receiving Evidence'
  when status='In Process' then 'Preparing'
  when status in ('Ready for Delivery','Delivered – Pending Customer Acceptance') then 'Awaiting Delivery Acceptance'
  when status='Completed' then case
    when exists(select 1 from public.payment_requests r where r.job_id=jobs.id and r.status='Pending Verification') then 'Payment Verification'
    when exists(select 1 from public.job_commercial_totals t where t.id=jobs.id and t.balance_due=0) then 'Closed'
    else 'Payment'
  end
  else work_stage
end;

create or replace function private.sync_payment_work_stage() returns trigger
language plpgsql security definer set search_path='' as $$
declare jid uuid;
begin
  jid:=new.job_id;
  if new.status='Pending Verification' then
    update public.jobs set work_stage='Payment Verification',updated_at=now() where id=jid;
  elsif new.status='Confirmed' then
    if exists(select 1 from public.job_commercial_totals where id=jid and balance_due=0) then
      update public.jobs set work_stage='Closed',updated_at=now() where id=jid;
    else
      update public.jobs set work_stage='Payment',updated_at=now() where id=jid;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists sync_payment_work_stage on public.payment_requests;
create trigger sync_payment_work_stage
after insert or update of status on public.payment_requests
for each row execute function private.sync_payment_work_stage();

revoke all on function private.sync_payment_work_stage() from public,anon,authenticated,service_role;

create or replace function public.advance_job(p_id uuid,p_action text)
returns text language plpgsql security definer set search_path='' as $$
declare j public.jobs; token text:=gen_random_uuid()::text||gen_random_uuid()::text;
begin
  select * into j from public.jobs where id=p_id for update;
  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  if p_action='start' and j.status='Authorized' and j.work_stage='Not Started' then
    update public.jobs set status='Receiving Documentation',work_stage='Receiving Evidence',customer_stage='In Process',updated_at=now() where id=j.id;
    return null;

  elsif p_action='receiving-done' and j.work_stage='Receiving Evidence' then
    if not exists(select 1 from public.documents where job_id=j.id and type='Receiving Evidence' and status='Available') then
      raise exception 'Add receiving evidence first';
    end if;
    update public.jobs set status='In Process',work_stage='Preparing',customer_stage='In Process',updated_at=now() where id=j.id;
    return null;

  elsif p_action='preparation-done' and j.work_stage='Preparing' then
    if exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent')) then
      raise exception 'Resolve pending extensions first';
    end if;
    update public.jobs set status='In Process',work_stage='Final Evidence',customer_stage='Engraving',updated_at=now() where id=j.id;
    return null;

  elsif p_action in ('finished','ready') and j.status='In Process' and j.work_stage in ('Final Evidence','Preparing') then
    if exists(select 1 from public.job_extensions where job_id=j.id and status in ('Requested','Draft','Sent')) then
      raise exception 'Resolve pending extensions first';
    end if;
    if not exists(
      select 1 from public.documents
      where job_id=j.id and type='Completed Evidence' and status='Available'
      and created_at>=coalesce((select max(accepted_at) from public.job_extensions where job_id=j.id),j.created_at)
    ) then raise exception 'Add completed work evidence first'; end if;

    update public.job_extensions set status='Completed' where job_id=j.id and status='Approved';
    insert into private.delivery_scopes(job_id,snapshot)
      values(j.id,private.job_portal_snapshot(j.id)) on conflict(job_id) do nothing;

    update public.jobs
    set status='Delivered – Pending Customer Acceptance',
        work_stage='Awaiting Delivery Acceptance',
        customer_stage='Completed',
        delivered_at=coalesce(delivered_at,now()),
        updated_at=now()
    where id=j.id;

    insert into private.public_links(token_hash,unit_id,job_id,expires_at)
      values(encode(sha256(convert_to(token,'UTF8')),'hex'),j.unit_id,j.id,now()+interval '30 days');

    insert into private.job_mail_links(job_id,token)
      values(j.id,token) on conflict(job_id) do update set token=excluded.token;

    insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
      values(j.unit_id,'Completion acknowledgment',j.id,'delivery:'||j.id,jsonb_build_object('live_eligible',true))
      on conflict do nothing;

    return token;

  elsif p_action='deliver' and j.status='Ready for Delivery' then
    insert into private.delivery_scopes(job_id,snapshot)
      values(j.id,private.job_portal_snapshot(j.id)) on conflict(job_id) do nothing;
    update public.jobs
    set status='Delivered – Pending Customer Acceptance',
        work_stage='Awaiting Delivery Acceptance',
        customer_stage='Completed',
        delivered_at=coalesce(delivered_at,now()),
        updated_at=now()
    where id=j.id;
    insert into private.public_links(token_hash,unit_id,job_id,expires_at)
      values(encode(sha256(convert_to(token,'UTF8')),'hex'),j.unit_id,j.id,now()+interval '30 days');
    insert into private.job_mail_links(job_id,token)
      values(j.id,token) on conflict(job_id) do update set token=excluded.token;
    insert into public.notifications(unit_id,event,entity_id,dedupe_key,payload)
      values(j.unit_id,'Completion acknowledgment',j.id,'delivery:'||j.id,jsonb_build_object('live_eligible',true))
      on conflict do nothing;
    return token;
  else
    raise exception 'Invalid job transition';
  end if;
end $$;

create or replace function public.public_completion(p_token text,p_decision text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.jobs; scope jsonb; customer uuid; snap jsonb;
begin
  select x.* into j
  from public.jobs x join private.public_links l on l.job_id=x.id
  where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and l.expires_at>now()
  for update of x;
  if j.id is null then raise exception 'Invalid or expired link'; end if;

  select snapshot into scope from private.delivery_scopes where job_id=j.id;
  scope:=coalesce(scope,private.job_portal_snapshot(j.id));

  if p_decision is not null then
    if p_decision='accept' and exists(select 1 from public.delivery_acknowledgments where job_id=j.id) then
      return scope||jsonb_build_object(
        'status',j.status,
        'reason',j.completion_reason,
        'acknowledgment',(select jsonb_build_object('id',a.id,'acknowledged_at',a.acknowledged_at) from public.delivery_acknowledgments a where a.job_id=j.id),
        'payment',private.job_payment_snapshot(j.id)
      );
    end if;

    if j.status<>'Delivered – Pending Customer Acceptance' then
      raise exception 'This delivery acknowledgment has already been resolved';
    end if;

    if p_decision='accept' then
      select customer_id into customer from public.commercial_flows where id=j.flow_id;
      snap:=jsonb_build_object(
        'job_id',j.id,'job_code',j.code,'customer_id',customer,'scope',scope,
        'delivered_at',j.delivered_at,'acknowledged_at',now(),
        'confirmation','I confirm that I received the items/work associated with this ToolTag Job.',
        'method','Secure link / electronic confirmation'
      );

      insert into public.delivery_acknowledgments(unit_id,job_id,customer_id,delivered_at,snapshot,snapshot_sha256)
      values(j.unit_id,j.id,customer,j.delivered_at,snap,encode(sha256(convert_to(snap::text,'UTF8')),'hex'))
      on conflict(job_id) do nothing;

      update public.jobs
      set status='Completed',
          work_stage=case
            when exists(select 1 from public.job_commercial_totals where id=j.id and balance_due=0) then 'Closed'
            else 'Payment'
          end,
          customer_accepted_at=now(),
          completion_reason='Completed – Customer Accepted',
          updated_at=now()
      where id=j.id;

    elsif p_decision='issue' then
      update public.jobs set status='Issue / Review',completion_reason='Customer reported an issue',updated_at=now() where id=j.id;
    else
      raise exception 'Invalid decision';
    end if;
  end if;

  update public.jobs
  set completion_link_viewed_at=coalesce(completion_link_viewed_at,now())
  where id=j.id returning * into j;

  return scope||jsonb_build_object(
    'status',j.status,
    'reason',j.completion_reason,
    'acknowledgment',(select jsonb_build_object('id',a.id,'acknowledged_at',a.acknowledged_at) from public.delivery_acknowledgments a where a.job_id=j.id),
    'payment',private.job_payment_snapshot(j.id)
  );
end $$;
