begin;
create table private.driver_block_terms (
 revision text primary key, policies jsonb not null, terms jsonb not null,
 effective_at timestamptz not null default now()
);
alter table private.driver_block_terms enable row level security;
revoke all on private.driver_block_terms from public,anon,authenticated;
create table public.driver_block_acceptances (
 id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units(id),
 route_id uuid not null references public.pick_return_routes(id), driver_id uuid not null references auth.users(id),
 revision text not null references private.driver_block_terms(revision), snapshot jsonb not null,
 snapshot_key text not null, insurance_valid_until date not null, registration_valid_until date not null,
 accepted_at timestamptz not null default now(), unique(route_id,driver_id,snapshot_key,insurance_valid_until,registration_valid_until)
);
alter table public.driver_block_acceptances enable row level security;
revoke all on public.driver_block_acceptances from public,anon,authenticated;
grant select on public.driver_block_acceptances to authenticated;
create policy driver_block_acceptances_read on public.driver_block_acceptances for select to authenticated
 using (private.has_any(unit_id,array['pr.routes.plan','pr.routes.live']) or (driver_id=auth.uid() and private.route_visible(route_id)));
insert into private.driver_block_terms(revision,policies,terms) values('1.0','[["Independent Contractor Status", "Drivers provide services as independent contractors, not as ToolTag employees. Follow the accepted block agreement for the assigned service."], ["Care of Items", "Protect every customer item from loss, damage and unauthorized use. Check the item list at every handoff and keep items secure throughout transport."], ["Lost Items — Driver Loss Agreement", "Report missing items immediately. The first loss requires acceptance of the warning and Owner authorization to remain eligible. A second or subsequent loss follows the separate Driver Loss Agreement for documented costs. ToolTag sends the final-cost agreement before any pay adjustment; the Owner records eligibility and noncompliance decisions."], ["Timely Service", "Follow the assigned route sequence and service windows. Report delays promptly and keep ToolTag informed before changing the route."], ["Communication", "Use the app to record departure, arrival and handoff updates. Contact ToolTag when a customer cannot be reached or a stop cannot be completed."], ["Prohibited Conduct", "Do not use customer tools, leave deliveries unattended, disclose customer information, or transfer items to an unauthorized person."], ["Schedules", "Confirm the block two hours before the route starts. Your driver block starts at the shop one hour before the route. Be at the shop then to verify and prepare the assigned items."], ["Photo Evidence", "Take clear photos of every side of each item at pickup and delivery, including existing damage. Upload receiving and delivery evidence in the correct app section before confirming the handoff."], ["Damage Reporting", "Report any damage or incident to ToolTag immediately, preserve the evidence and record what happened in the app. Do not conceal damage or promise an unauthorized resolution."], ["Professional Conduct", "Treat customers, staff and their property respectfully. Follow safe driving practices and ToolTag instructions throughout the assigned block."]]'::jsonb,'[["Payment terms", "ToolTag pays weekly on Friday by bank deposit, at 85% of what ToolTag charges for the assigned services. Drivers work as independent contractors and receive a 1099."], ["Driver cancellation", "Your driver block starts at the shop one hour before the route starts. Cancel at least one hour before your driver block starts (two hours before the route). For a 2–6 PM route, your block starts at 1 PM and you must cancel by 12 PM. Late cancellations are reviewed based on frequency."], ["ToolTag cancellation", "ToolTag may cancel until two hours before the route starts. After that deadline, compensation is $10 if notice is given before you arrive at the shop, or $20 if ToolTag cancels after you arrive at the shop."], ["No-show", "The first no-show results in a one-month block, the second in a three-month block, and the third in a permanent ban."], ["Vehicle and insurance", "Active vehicle insurance and up-to-date vehicle registration are required to be eligible for a block."]]'::jsonb);
create function private.driver_block_snapshot(p_route uuid) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('revision',t.revision,'policies',t.policies,'terms',t.terms,
 'route_id',r.id,'route_date',r.route_date,'leg',case r.leg when 'Return' then 'Delivery' else 'Pick Up' end,
 'driver_id',r.operator_id,'driver_name',(select a.display_name from public.staff_access a where a.user_id=r.operator_id and a.unit_id=r.unit_id),'block_number',r.block_number,'route_start',((r.route_date+case r.leg when 'Pickup' then time '08:00' else time '14:00' end) at time zone 'America/Denver'),
 'block_start',((r.route_date+case r.leg when 'Pickup' then time '07:00' else time '13:00' end) at time zone 'America/Denver'),
 'stops',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'job',j.code,'sequence',s.sequence,'window_start',s.window_start,'window_end',s.window_end) order by s.sequence,s.id)
 from public.pick_return_stops s join public.jobs j on j.id=s.job_id where s.route_id=r.id and s.status not in ('Cancelled','Failed')),'[]'))
 from public.pick_return_routes r cross join lateral (select * from private.driver_block_terms where effective_at<=now() order by effective_at desc limit 1)t where r.id=p_route
$$;
revoke all on function private.driver_block_snapshot(uuid) from public,anon,authenticated;
create function public.driver_block_agreement(p_route uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;s jsonb;k text;a public.driver_block_acceptances;begin
 perform private.require_route(p_route);
 select * into r from public.pick_return_routes where id=p_route;
 s:=private.driver_block_snapshot(r.id);k:=md5(s::text);
 select * into a from public.driver_block_acceptances where route_id=r.id and driver_id=r.operator_id and snapshot_key=k and insurance_valid_until>=r.route_date and registration_valid_until>=r.route_date order by accepted_at desc limit 1;
 return jsonb_build_object('snapshot',s,'key',k,'accepted',a.id is not null,'accepted_at',a.accepted_at,'can_accept',r.operator_id=auth.uid() and private.driver_loss_eligible(auth.uid()) and r.departed_at is null and r.status not in ('Completed','Cancelled') and now()<=(s->>'route_start')::timestamptz-interval '2 hours');
end$$;
create function public.accept_driver_block(p_route uuid,p_key text,p_insurance_until date,p_registration_until date) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;s jsonb;k text;aid uuid;begin
 perform private.require_route(p_route);
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.operator_id is distinct from auth.uid() then raise exception 'Only the assigned driver may accept this block';end if;
 if not private.driver_loss_eligible(auth.uid()) then raise exception 'Driver is not eligible for assignments';end if;
 if r.departed_at is not null or r.status in ('Completed','Cancelled') then raise exception 'Block is already started or closed';end if;
 if p_insurance_until is null or p_registration_until is null or least(p_insurance_until,p_registration_until)<greatest(current_date,r.route_date) then raise exception 'Active insurance and current registration through the route date are required';end if;
 s:=private.driver_block_snapshot(r.id);k:=md5(s::text);
 if now()>(s->>'route_start')::timestamptz-interval '2 hours' then raise exception 'Block confirmation deadline has passed. Contact ToolTag';end if;
 if p_key is distinct from k then raise exception 'Block changed. Review the updated agreement before accepting';end if;
 insert into public.driver_block_acceptances(unit_id,route_id,driver_id,revision,snapshot,snapshot_key,insurance_valid_until,registration_valid_until)
 values(r.unit_id,r.id,auth.uid(),s->>'revision',s,k,p_insurance_until,p_registration_until)
 on conflict(route_id,driver_id,snapshot_key,insurance_valid_until,registration_valid_until) do nothing returning id into aid;
 if aid is null then select id into aid from public.driver_block_acceptances where route_id=r.id and driver_id=auth.uid() and snapshot_key=k and insurance_valid_until=p_insurance_until and registration_valid_until=p_registration_until;end if;
 return aid;
end$$;
revoke all on function public.driver_block_agreement(uuid),public.accept_driver_block(uuid,text,date,date) from public,anon;
grant execute on function public.driver_block_agreement(uuid),public.accept_driver_block(uuid,text,date,date) to authenticated;
alter function public.depart_driver_route(uuid) rename to depart_driver_route_before_block_acceptance;
revoke all on function public.depart_driver_route_before_block_acceptance(uuid) from public,anon,authenticated;
create function public.depart_driver_route(p_route uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.pick_return_routes;begin
 perform private.require_route(p_route);
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.departed_at is null and r.operator_id is not null and not coalesce((public.driver_block_agreement(r.id)->>'accepted')::boolean,false) then raise exception 'Assigned driver must accept the current block agreement with valid insurance and registration before departure';end if;
 return public.depart_driver_route_before_block_acceptance(p_route);
end$$;
revoke all on function public.depart_driver_route(uuid) from public,anon;
grant execute on function public.depart_driver_route(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
