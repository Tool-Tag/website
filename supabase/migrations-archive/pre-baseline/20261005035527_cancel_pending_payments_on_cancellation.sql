
alter table public.pick_return_orders
  drop constraint if exists pick_return_orders_fee_status_check;

alter table public.pick_return_orders
  add constraint pick_return_orders_fee_status_check
  check (fee_status in (
    'Required','Pending Verification','Confirmed',
    'Refund Pending','Refunded','Forfeited','Cancelled'
  ));

create or replace function private.apply_pending_cancellation(p_job uuid)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare
  r public.cancellation_requests;
  pr public.pick_return_orders;
  settlement numeric(14,2);
begin
  select * into r
  from public.cancellation_requests
  where job_id=p_job and status='Requested'
  order by requested_at
  limit 1
  for update;

  if r.id is null then return false; end if;

  settlement:=coalesce(
    nullif(r.assessment->>'settlement_amount','')::numeric,
    r.service_charge_amount
      + case
          when coalesce((r.assessment->>'pickup_fee_paid')::numeric,0)>0
               and not r.pickup_fee_refundable
          then r.pickup_fee_amount
          else 0
        end
  );

  perform private.settle_cancelled_sales(p_job,settlement);

  update public.payment_requests
  set status='Cancelled'
  where job_id=p_job
    and status='Pending Verification';

  update public.jobs
  set status='Cancelled',
      completion_reason='Cancelled by customer request',
      updated_at=now()
  where id=p_job;

  update public.cancellation_requests
  set status='Cancelled',
      confirmed_at=now(),
      cancelled_at=now()
  where id=r.id;

  update public.job_items
  set stage='Cancelled',
      cancelled_at=coalesce(cancelled_at,now()),
      updated_at=now()
  where job_id=p_job and stage<>'Finished';

  select * into pr
  from public.pick_return_orders
  where job_id=p_job
  for update;

  if pr.job_id is not null then
    if pr.pickup_status<>'Picked Up' then
      update public.pick_return_orders
      set pickup_status='Cancelled',
          return_status='Cancelled',
          fee_status=case
            when r.pickup_fee_refund_amount>0 then 'Refund Pending'
            when fee_status='Confirmed' then 'Forfeited'
            when fee_status in ('Required','Pending Verification') then 'Cancelled'
            else fee_status
          end,
          updated_at=now()
      where job_id=p_job;

      update public.pick_return_stops
      set status='Cancelled'
      where job_id=p_job and status in ('Scheduled','En Route','Arrived');
    else
      update public.pick_return_orders
      set hold_until_paid=(r.amount_due>0),
          return_status=case
            when r.amount_due>0 then 'Not Ready'
            else 'Delivery In Progress'
          end,
          fee_status=case
            when r.pickup_fee_refund_amount>0 then 'Refund Pending'
            when fee_status='Confirmed' then 'Forfeited'
            else fee_status
          end,
          updated_at=now()
      where job_id=p_job;

      update public.pick_return_stops s
      set status='Cancelled'
      from public.pick_return_routes rt
      where s.route_id=rt.id
        and s.job_id=p_job
        and rt.leg='Pickup'
        and s.status in ('Scheduled','En Route','Arrived');
    end if;
  end if;

  return true;
end $$;
