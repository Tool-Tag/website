
create or replace function public.complete_job_work(p_job uuid)
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  total_items integer;
  finished_items integer;
  token text;
begin
  select * into j from public.jobs where id=p_job for update;
  if j.id is null then raise exception 'Job not found'; end if;
  perform private.require_admin(j.unit_id);

  if private.apply_pending_cancellation(j.id) then
    raise exception 'Cancellation request detected; this Job cannot continue';
  end if;

  if j.status='Cancelled' then
    raise exception 'This Job is cancelled';
  end if;

  if exists(
    select 1 from public.job_extensions
    where job_id=j.id and status in ('Requested','Draft','Sent')
  ) then
    raise exception 'Resolve pending extensions first';
  end if;

  select count(*), count(*) filter (where stage='Finished')
  into total_items, finished_items
  from public.job_items
  where job_id=j.id;

  if total_items=0 or finished_items<>total_items then
    raise exception 'Finish every Job item before completing the work';
  end if;

  update public.job_extensions
  set status='Completed'
  where job_id=j.id and status='Approved';

  if exists(select 1 from public.pick_return_orders where job_id=j.id) then
    update public.jobs
    set work_stage='Delivery In Progress',
        customer_stage='Final Details',
        updated_at=now()
    where id=j.id
      and work_stage<>'Delivery In Progress';

    update public.pick_return_orders
    set return_status=case
          when return_status='Not Ready' then 'Delivery In Progress'
          else return_status
        end,
        updated_at=now()
    where job_id=j.id;

    return null;
  end if;

  token:=private.begin_delivery_acceptance(j.id);
  return token;
end $$;

revoke all on function public.complete_job_work(uuid) from public,anon;
grant execute on function public.complete_job_work(uuid) to authenticated;

create or replace function public.public_job_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  j public.jobs;
  customer_name text;
  prog jsonb;
  pr jsonb;
  tracking_stage text;
  tracking_steps jsonb;
  pickup_status text;
  return_status text;
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

  prog:=private.job_item_progress(j.id);

  select to_jsonb(x)-'unit_id'-'terms_snapshot',
         x.pickup_status,
         x.return_status
  into pr,pickup_status,return_status
  from public.pick_return_orders x
  where x.job_id=j.id;

  if pr is not null then
    tracking_steps:=jsonb_build_array(
      'Pickup Fee','Pickup Scheduled','Pickup In Progress','Picked Up',
      'In Process','Engraving','Delivery In Progress','Return Scheduled',
      'Out for Delivery','Delivered','Completed'
    );

    tracking_stage:=case
      when j.status='Completed' or j.work_stage='Closed' then 'Completed'
      when return_status='Delivered' then 'Delivered'
      when return_status in ('En Route','Arrived') then 'Out for Delivery'
      when return_status='Scheduled' then 'Return Scheduled'
      when return_status='Delivery In Progress' then 'Delivery In Progress'
      when j.customer_stage='Engraving' then 'Engraving'
      when pickup_status='Picked Up' then 'In Process'
      when pickup_status in ('En Route','Arrived') then 'Pickup In Progress'
      when pickup_status='Scheduled' then 'Pickup Scheduled'
      when coalesce(pr->>'fee_status','Required')<>'Confirmed' then 'Pickup Fee'
      else 'Pickup Scheduled'
    end;
  else
    tracking_steps:=jsonb_build_array(
      'In Process','Engraving','Final Details','Completed'
    );
    tracking_stage:=j.customer_stage;
  end if;

  return jsonb_build_object(
    'code',j.code,
    'customer_name',customer_name,
    'stage',j.customer_stage,
    'tracking_stage',tracking_stage,
    'job_status',j.status,
    'work_stage',j.work_stage,
    'updated_at',j.updated_at,
    'items_total',coalesce((prog->>'total')::integer,0),
    'items_completed',coalesce((prog->>'finished')::integer,0),
    'items_started',coalesce((prog->>'started')::integer,0),
    'item_progress',prog,
    'pickup_return',pr,
    'cancelled',j.status='Cancelled',
    'steps',tracking_steps
  );
end $$;

update public.jobs j
set work_stage='Engraving', updated_at=now()
where j.work_stage='Final Evidence'
  and exists (
    select 1 from public.job_items ji
    where ji.job_id=j.id and ji.stage in ('Engraving','Finished Evidence')
  );
