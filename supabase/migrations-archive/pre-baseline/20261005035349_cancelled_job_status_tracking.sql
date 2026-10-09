
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
  hold_until_paid boolean:=false;
  cancellation public.cancellation_requests;
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

  select
    to_jsonb(x)-'unit_id'-'terms_snapshot',
    x.pickup_status,
    x.return_status,
    x.hold_until_paid
  into pr,pickup_status,return_status,hold_until_paid
  from public.pick_return_orders x
  where x.job_id=j.id;

  if j.status='Cancelled' then
    select * into cancellation
    from public.cancellation_requests c
    where c.job_id=j.id and c.status='Cancelled'
    order by c.cancelled_at desc,c.created_at desc
    limit 1;

    if cancellation.id is not null then
      prog:=jsonb_build_object(
        'total',cancellation.items_total,
        'started',cancellation.items_started,
        'finished',cancellation.items_finished,
        'cancelled',greatest(cancellation.items_total-cancellation.items_finished,0),
        'current_item_id',null,
        'current_sequence',null
      );
    end if;

    if pr is not null and pickup_status='Picked Up' then
      tracking_steps:=jsonb_build_array(
        'Cancelled',
        'Cancellation Balance',
        'Delivery In Progress',
        'Return Scheduled',
        'Out for Delivery',
        'Delivered'
      );

      tracking_stage:=case
        when return_status='Delivered' then 'Delivered'
        when return_status in ('En Route','Arrived') then 'Out for Delivery'
        when return_status='Scheduled' then 'Return Scheduled'
        when hold_until_paid then 'Cancellation Balance'
        else 'Delivery In Progress'
      end;
    else
      tracking_steps:=jsonb_build_array('Cancelled');
      tracking_stage:='Cancelled';
    end if;

  elsif pr is not null then
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
