-- Phase A: ToolTag RBAC. Forward-only; no Agreement or BOFT data changes.
-- Production application must wait for branch audit approval.
begin;
do $$begin if not exists(select 1 from public.business_units where id='10000000-0000-0000-0000-000000000002' and code='TOOLTAG') then raise exception 'Canonical ToolTag unit is required';end if;end$$;
create table public.permission_blocks(key text primary key, description text not null, area text not null);
create table public.roles(id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.business_units(id), name text not null check(length(trim(name)) between 1 and 80), system_key text check(system_key in ('Owner','Employee','Driver')), unique(unit_id,name), unique(unit_id,system_key), unique(id,unit_id));
create table public.role_blocks(role_id uuid not null references public.roles(id) on delete cascade, block_key text not null references public.permission_blocks(key), primary key(role_id,block_key));
create table public.staff_access(unit_id uuid not null references public.business_units(id), user_id uuid not null references auth.users(id), active boolean not null default true, display_name text not null default '', primary key(unit_id,user_id));
create table public.user_roles(unit_id uuid not null, user_id uuid not null, role_id uuid not null, primary key(unit_id,user_id,role_id), foreign key(unit_id,user_id) references public.staff_access(unit_id,user_id), foreign key(role_id,unit_id) references public.roles(id,unit_id));
alter table public.pick_return_routes add column operator_id uuid references auth.users(id);
create index pick_return_routes_operator_day on public.pick_return_routes(operator_id,route_date) where operator_id is not null;
create index user_roles_role on public.user_roles(role_id);
alter table public.permission_blocks enable row level security;
alter table public.roles enable row level security;
alter table public.role_blocks enable row level security;
alter table public.staff_access enable row level security;
alter table public.user_roles enable row level security;
revoke all on public.permission_blocks,public.roles,public.role_blocks,public.staff_access,public.user_roles from anon,authenticated;
grant select on public.permission_blocks,public.roles,public.role_blocks,public.staff_access,public.user_roles to authenticated;
insert into public.permission_blocks(key,description,area) values
('jobs.view','View jobs','Operations'),
('jobs.manage','Manage jobs and extensions','Operations'),
('production.work','Work on production items','Operations'),
('quotes.view','View quotes and requests','Operations'),
('quotes.manage','Create, review and send quotes','Operations'),
('customers.view','View customers','Operations'),
('pr.routes.plan','Plan and assign routes','Pick & Return'),
('pr.routes.live','Operate live routes','Pick & Return'),
('pr.receiving','Verify received pieces at the shop','Pick & Return'),
('pr.returns','Verify returned pieces and close returns','Pick & Return'),
('pr.reschedule','Reschedule stops','Pick & Return'),
('payments.record','Record and verify payments','Money'),
('payments.view','View financial records','Money'),
('payments.refund','Issue and confirm refunds','Money'),
('settings.manage','Manage workspace settings','System'),
('users.manage','Manage users and roles','System'),
('driver.routes','Operate assigned routes, collect route cash and upload evidence','Driver'),
('support.inbox','Read and reply to the support inbox','Support');
insert into public.roles(unit_id,name,system_key) select id,k,k from public.business_units cross join unnest(array['Owner','Employee','Driver']) k where id='10000000-0000-0000-0000-000000000002';
insert into public.staff_access(unit_id,user_id,display_name) select unit_id,user_id,'' from public.memberships where unit_id='10000000-0000-0000-0000-000000000002';
-- Approved bootstrap: legacy ToolTag admins become Owners; no viewer is promoted.
insert into public.user_roles(unit_id,user_id,role_id) select m.unit_id,m.user_id,r.id from public.memberships m join public.roles r on r.unit_id=m.unit_id and r.system_key='Owner' where m.role='admin';
insert into public.role_blocks select r.id,b.key from public.roles r cross join public.permission_blocks b where r.system_key='Owner';
insert into public.role_blocks select r.id,k from public.roles r cross join unnest(array['jobs.view','jobs.manage','production.work','quotes.view','customers.view','pr.routes.plan','pr.routes.live','pr.receiving','pr.returns','pr.reschedule','payments.record','support.inbox']) k where r.system_key='Employee';
insert into public.role_blocks select id,'driver.routes' from public.roles where system_key='Driver';
create function private.staff_active(u uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.staff_access where unit_id=u and user_id=auth.uid() and active) and exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid())$$;
create function private.is_owner(u uuid) returns boolean language sql stable security definer set search_path='' as $$select private.staff_active(u) and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id and r.unit_id=ur.unit_id where ur.unit_id=u and ur.user_id=auth.uid() and r.system_key='Owner')$$;
create function private.has_block(u uuid,k text) returns boolean language sql stable security definer set search_path='' as $$select private.staff_active(u) and (private.is_owner(u) or exists(select 1 from public.user_roles ur join public.role_blocks b on b.role_id=ur.role_id where ur.unit_id=u and ur.user_id=auth.uid() and b.block_key=k))$$;
create function private.has_any(u uuid,ks text[]) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from unnest(ks) k where private.has_block(u,k))$$;
create function private.read_permission(u uuid,ks text[]) returns boolean language sql stable security definer set search_path='' as $$select case when u='10000000-0000-0000-0000-000000000002' then case when 'settings.manage'=any(ks) then private.is_owner(u) else private.has_any(u,ks) end else exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid()) end$$;
create function private.require_owner(u uuid) returns void language plpgsql security definer set search_path='' as $$begin if not private.is_owner(u) then raise exception 'Owner access required' using errcode='42501';end if;end$$;
create or replace function private.can_access(u uuid) returns boolean language sql stable security definer set search_path='' as $$select case when u='10000000-0000-0000-0000-000000000002' then private.staff_active(u) else exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid()) end$$;
-- Preserve non-ToolTag legacy behavior; unknown privileged operations are Owner-only.
create or replace function private.require_admin(u uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if auth.role()='service_role' then return;end if;
 if u='10000000-0000-0000-0000-000000000002' then perform private.require_owner(u);
 elsif not exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid() and role='admin') then raise exception 'Administrative access required' using errcode='42501';end if;
end$$;
create or replace function private.can_view_physical(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.accounts where physical_account_id=p_id) and not exists(select 1 from public.accounts where physical_account_id=p_id and (not private.can_access(unit_id) or (unit_id='10000000-0000-0000-0000-000000000002' and not private.has_block(unit_id,'payments.view'))))$$;
create function private.route_visible(p_route uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.pick_return_routes r where r.id=p_route and ((r.unit_id<>'10000000-0000-0000-0000-000000000002' and private.can_access(r.unit_id)) or (private.staff_active(r.unit_id) and (private.has_any(r.unit_id,array['pr.routes.plan','pr.routes.live','pr.receiving','pr.returns','pr.reschedule']) or (private.has_block(r.unit_id,'driver.routes') and r.operator_id=auth.uid())))))$$;
create function private.job_on_assigned_route(p_job uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.pick_return_stops s join public.pick_return_routes r on r.id=s.route_id where s.job_id=p_job and r.operator_id=auth.uid() and private.has_block(r.unit_id,'driver.routes'))$$;
create function private.require_route(p_route uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if auth.role()='service_role' then return;end if;
 if not private.route_visible(p_route) then raise exception 'Route is not assigned to this account' using errcode='42501';end if;
end$$;
create function private.require_stop(p_stop uuid) returns void language plpgsql security definer set search_path='' as $$declare rid uuid;begin select route_id into rid from public.pick_return_stops where id=p_stop;perform private.require_route(rid);end$$;
-- Append-only action log; never records credentials, tokens or email bodies.
create function private.rbac_log(action text,target uuid,details jsonb default '{}') returns void language sql security definer set search_path='' as $$insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values('10000000-0000-0000-0000-000000000002',auth.uid(),'rbac',target,action,details)$$;
create function public.staff_permissions() returns jsonb language sql stable security definer set search_path='' as $$select jsonb_build_object('active',private.staff_active('10000000-0000-0000-0000-000000000002'),'owner',private.is_owner('10000000-0000-0000-0000-000000000002'),'blocks',coalesce((select jsonb_agg(key order by key) from public.permission_blocks where private.has_block('10000000-0000-0000-0000-000000000002',key)),'[]'))$$;
create function public.rbac_directory() returns jsonb language plpgsql security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';begin perform private.require_owner(u);
 return jsonb_build_object('blocks',(select jsonb_agg(to_jsonb(b) order by area,key) from public.permission_blocks b),'roles',(select jsonb_agg(to_jsonb(r)||jsonb_build_object('blocks',coalesce((select jsonb_agg(block_key order by block_key) from public.role_blocks b where b.role_id=r.id),'[]')) order by name) from public.roles r where unit_id=u),'users',coalesce((select jsonb_agg(jsonb_build_object('id',a.user_id,'email',x.email,'name',a.display_name,'active',a.active,'roles',coalesce((select jsonb_agg(role_id) from public.user_roles where unit_id=u and user_id=a.user_id),'[]')) order by x.email) from public.staff_access a join auth.users x on x.id=a.user_id where a.unit_id=u),'[]'));
end$$;
create function public.rbac_save_role(p_id uuid,p_name text,p_blocks text[]) returns uuid language plpgsql security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';rid uuid;system text;begin perform private.require_owner(u);perform pg_advisory_xact_lock(hashtext(u::text));
 if exists(select 1 from unnest(p_blocks) b where not exists(select 1 from public.permission_blocks where key=b)) then raise exception 'Unknown permission block';end if;
 if p_id is not null then select id,system_key into rid,system from public.roles where id=p_id and unit_id=u for update;if rid is null then raise exception 'Role unavailable';end if;if system='Owner' then raise exception 'Owner is immutable and includes all current and future blocks';end if;update public.roles set name=trim(p_name) where id=rid;
 else insert into public.roles(unit_id,name) values(u,trim(p_name)) returning id into rid;end if;
 delete from public.role_blocks where role_id=rid;
 insert into public.role_blocks select rid,b from (select distinct unnest(coalesce(p_blocks,'{}')) b) x;
 perform private.rbac_log('role.saved',rid,jsonb_build_object('name',trim(p_name),'blocks',p_blocks));return rid;
end$$;
create function public.rbac_save_user(p_user uuid,p_name text,p_active boolean,p_roles uuid[]) returns void language plpgsql security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';owner_role uuid;begin perform private.require_owner(u);perform pg_advisory_xact_lock(hashtext(u::text));
 if not exists(select 1 from auth.users where id=p_user) or length(p_name)>100 then raise exception 'User unavailable';end if;
 if exists(select 1 from unnest(p_roles) rid where not exists(select 1 from public.roles where id=rid and unit_id=u)) then raise exception 'Invalid role';end if;
 select id into owner_role from public.roles where unit_id=u and system_key='Owner';
 if (not p_active or not owner_role=any(coalesce(p_roles,'{}'))) and exists(select 1 from public.user_roles where unit_id=u and user_id=p_user and role_id=owner_role) and not exists(select 1 from public.user_roles ur join public.staff_access a using(unit_id,user_id) where ur.unit_id=u and ur.role_id=owner_role and a.active and ur.user_id<>p_user) then raise exception 'Keep at least one active Owner';end if;
 insert into public.memberships(unit_id,user_id,role) values(u,p_user,'viewer') on conflict do nothing;
 insert into public.staff_access(unit_id,user_id,display_name,active) values(u,p_user,trim(p_name),p_active) on conflict(unit_id,user_id) do update set display_name=excluded.display_name,active=excluded.active;
 delete from public.user_roles where unit_id=u and user_id=p_user;
 insert into public.user_roles select u,p_user,rid from (select distinct unnest(coalesce(p_roles,'{}')) rid) x;
 perform private.rbac_log('user.access.saved',p_user,jsonb_build_object('active',p_active,'roles',p_roles));
end$$;
create function public.rbac_log_credential_reset(p_user uuid) returns void language plpgsql security definer set search_path='' as $$begin perform private.require_owner('10000000-0000-0000-0000-000000000002');if not exists(select 1 from public.staff_access where unit_id='10000000-0000-0000-0000-000000000002' and user_id=p_user) then raise exception 'User unavailable';end if;perform private.rbac_log('user.credential_reset.requested',p_user);end$$;
create function public.assign_route_operator(p_route uuid,p_operator uuid) returns void language plpgsql security definer set search_path='' as $$declare r public.pick_return_routes;begin
 select * into r from public.pick_return_routes where id=p_route for update;
 if r.unit_id is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.has_block(r.unit_id,'pr.routes.plan') then raise exception 'Route planning permission required' using errcode='42501';end if;
 if r.confirmed_at is not null or r.status in ('Completed','Cancelled') then raise exception 'Closed routes cannot be reassigned';end if;
 if p_operator is not null and not exists(select 1 from public.staff_access a where a.unit_id=r.unit_id and a.user_id=p_operator and a.active and exists(select 1 from public.user_roles ur join public.roles rr on rr.id=ur.role_id left join public.role_blocks b on b.role_id=ur.role_id where ur.unit_id=a.unit_id and ur.user_id=a.user_id and (rr.system_key='Owner' or b.block_key in ('driver.routes','pr.routes.live')))) then raise exception 'Choose an active route operator';end if;
 update public.pick_return_routes set operator_id=p_operator where id=r.id;perform private.rbac_log('route.assigned',r.id,jsonb_build_object('operator_id',p_operator));
end$$;
create function public.route_operators() returns jsonb language plpgsql security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';begin if not private.has_block(u,'pr.routes.plan') then raise exception 'Route planning permission required' using errcode='42501';end if;return coalesce((select jsonb_agg(jsonb_build_object('id',a.user_id,'name',coalesce(nullif(a.display_name,''),'Route operator'))) from public.staff_access a where a.unit_id=u and a.active and exists(select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id left join public.role_blocks b on b.role_id=ur.role_id where ur.unit_id=u and ur.user_id=a.user_id and (r.system_key='Owner' or b.block_key in ('driver.routes','pr.routes.live')))),'[]');end$$;
create function private.rbac_action_blocks(action text) returns text[] language sql immutable set search_path='' as $$select ks from (values
('job_customer_status',array['jobs.view']::text[]),
('job_lifecycle',array['jobs.view']::text[]),
('advance_job',array['jobs.manage']::text[]),
('set_job_customer_stage',array['jobs.manage']::text[]),
('request_job_extension',array['jobs.manage']::text[]),
('cancel_job_extension',array['jobs.manage']::text[]),
('request_job_cancellation',array['jobs.manage']::text[]),
('advance_job_item',array['production.work']::text[]),
('complete_job_production',array['production.work']::text[]),
('quote_delivery',array['quotes.view']::text[]),
('get_tagged_attention',array['quotes.view']::text[]),
('get_get_tagged_request',array['quotes.view']::text[]),
('get_tagged_pending_count',array['quotes.view']::text[]),
('accepted_pdf_file',array['quotes.view']::text[]),
('create_quote',array['quotes.manage']::text[]),
('send_quote_to',array['quotes.manage']::text[]),
('resend_quote',array['quotes.manage']::text[]),
('resolve_get_tagged',array['quotes.manage']::text[]),
('approve_get_tagged',array['quotes.manage']::text[]),
('reject_get_tagged',array['quotes.manage']::text[]),
('review_get_tagged_quote',array['quotes.manage']::text[]),
('save_job_extension',array['quotes.manage']::text[]),
('send_job_extension',array['quotes.manage']::text[]),
('claim_mail_for_mode',array['quotes.manage']::text[]),
('claim_quote_mail',array['quotes.manage']::text[]),
('finish_quote_mail',array['quotes.manage']::text[]),
('prepare_existing_accepted_document',array['quotes.manage']::text[]),
('claim_accepted_pdf',array['quotes.manage']::text[]),
('finish_accepted_pdf',array['quotes.manage']::text[]),
('claim_accepted_copy',array['quotes.manage']::text[]),
('claim_document_copy',array['quotes.manage']::text[]),
('retry_accepted_document',array['quotes.manage']::text[]),
('authorize_document_live_copies',array['quotes.manage']::text[]),
('finish_accepted_pdf_storage',array['quotes.manage']::text[]),
('search_records',array['customers.view']::text[]),
('vehicle_report',array['payments.view']::text[]),
('dashboard_stats',array['payments.view']::text[]),
('customer_stats',array['payments.view']::text[]),
('generate_job_receipt',array['payments.record','driver.routes']::text[]),
('confirm_payment_request',array['payments.record','driver.routes']::text[]),
('confirm_cancellation_refund',array['payments.refund']::text[]),
('confirm_route_refund',array['payments.refund']::text[]),
('save_settings',array['settings.manage']::text[]),
('sms_settings_status',array['settings.manage']::text[]),
('save_sms_settings',array['settings.manage']::text[]),
('reserve_sms_test',array['settings.manage']::text[]),
('activate_customer_mail',array['settings.manage']::text[]),
('customer_mail_status',array['settings.manage']::text[]),
('retry_customer_notification',array['settings.manage']::text[]),
('publish_policy',array['settings.manage']::text[]),
('route_schedule',array['pr.reschedule']::text[]),
('schedule_pick_return',array['pr.reschedule']::text[]),
('verify_shop_item',array['pr.receiving']::text[]),
('pickup_driver_action',array['pr.routes.live','driver.routes']::text[]),
('return_driver_action',array['pr.routes.live','driver.routes']::text[]),
('advance_pick_return_stop',array['pr.routes.live','driver.routes']::text[]),
('depart_driver_route',array['pr.routes.live','driver.routes']::text[]),
('driver_route_estimate_context',array['pr.routes.live','driver.routes']::text[]),
('update_driver_route_estimates',array['pr.routes.live','driver.routes']::text[]),
('report_driver_incident',array['pr.routes.live','driver.routes']::text[]),
('resolve_driver_incident',array['pr.routes.live','driver.routes']::text[]),
('route_live_channel',array['pr.routes.live','driver.routes']::text[]),
('collect_route_cash',array['payments.record','driver.routes']::text[]),
('confirm_pick_return_route',array['pr.receiving','pr.returns','pr.routes.live','driver.routes']::text[]),
('verify_route_items',array['pr.returns','pr.routes.live','driver.routes']::text[]),
('route_item_checklist',array['pr.returns','pr.routes.live','driver.routes']::text[]),
('confirm_shop_handover',array['pr.returns']::text[]),
('register_document_metadata',array['production.work','pr.receiving','pr.returns','jobs.manage','quotes.manage','payments.record','driver.routes','pr.routes.live']::text[]),
('finish_document_storage',array['production.work','pr.receiving','pr.returns','jobs.manage','quotes.manage','payments.record','driver.routes','pr.routes.live']::text[]),
('update_document_evidence_metadata',array['production.work','pr.receiving','pr.returns','jobs.manage','quotes.manage','payments.record','driver.routes','pr.routes.live']::text[])) m(name,ks) where name=action$$;
create function private.require_rbac(action text,u uuid) returns void language plpgsql security definer set search_path='' as $$begin
 if auth.role()='service_role' then return;end if;
 if u is distinct from '10000000-0000-0000-0000-000000000002'::uuid then perform private.require_admin(u);return;end if;
 if action in ('save_settings','sms_settings_status','save_sms_settings','reserve_sms_test','activate_customer_mail','customer_mail_status','retry_customer_notification','publish_policy') then perform private.require_owner(u);return;end if;
 if not private.is_owner(u) and not private.has_any(u,coalesce(private.rbac_action_blocks(action),'{}')) then raise exception 'Permission denied: %',action using errcode='42501';end if;
end$$;
create function private.require_cash_request(p_id uuid) returns void language plpgsql security definer set search_path='' as $$declare pr public.payment_requests;s public.pick_return_stops;begin
 if auth.role()='service_role' then return;end if;
 select * into pr from public.payment_requests where id=p_id;
 if private.has_block(pr.unit_id,'payments.record') then return;end if;
 select * into s from public.pick_return_stops where id=pr.request_key and job_id=pr.job_id and status='Arrived';
 if s.id is null or pr.method<>'Cash' or pr.purpose<>'Final Balance' or not exists(select 1 from public.pick_return_routes where id=s.route_id and leg='Return') then raise exception 'Only cash at your Arrived Return stop may be confirmed' using errcode='42501';end if;
 perform private.require_stop(s.id);
end$$;
create function private.require_receipt_scope(p_job uuid) returns void language plpgsql security definer set search_path='' as $$declare u uuid;begin
 if auth.role()='service_role' then return;end if;select unit_id into u from public.jobs where id=p_job;
 if private.has_block(u,'payments.record') then return;end if;
 if not private.job_on_assigned_route(p_job) or not exists(select 1 from public.payment_requests pr join public.pick_return_stops ss on ss.id=pr.request_key and ss.job_id=pr.job_id join public.pick_return_routes rr on rr.id=ss.route_id where pr.job_id=p_job and pr.method='Cash' and pr.status='Confirmed' and rr.operator_id=auth.uid() and rr.leg='Return' and ss.status='Arrived') then raise exception 'Route receipt unavailable' using errcode='42501';end if;
end$$;
-- Restrictive policies combine with existing tenant policies (cannot broaden them).
create function private.rbac_row(table_key text,row_data jsonb) returns boolean language plpgsql stable security definer set search_path='' as $$declare u uuid:=(row_data->>'unit_id')::uuid;j uuid;f uuid;begin
 if u is distinct from '10000000-0000-0000-0000-000000000002'::uuid then return true;end if;
 if not private.staff_active(u) then return false;end if;
 if private.is_owner(u) then return true;end if;
 case table_key
 when 'pick_return_routes' then return private.route_visible((row_data->>'id')::uuid);
 when 'pick_return_stops' then return private.route_visible((row_data->>'route_id')::uuid);
 when 'route_incidents' then return private.route_visible((row_data->>'route_id')::uuid);
 when 'route_incident_jobs' then return exists(select 1 from public.route_incidents i where i.id=(row_data->>'incident_id')::uuid and private.route_visible(i.route_id));
 when 'unit_settings' then return private.has_any(u,array['settings.manage','pr.routes.plan','pr.routes.live','pr.receiving','pr.returns','pr.reschedule','driver.routes','payments.record']);
 when 'customers' then return private.has_any(u,array['customers.view','quotes.manage','jobs.manage','pr.receiving','pr.returns','pr.routes.plan','pr.routes.live','pr.reschedule']) or exists(select 1 from public.commercial_flows cf join public.jobs jj on jj.flow_id=cf.id where cf.customer_id=(row_data->>'id')::uuid and private.job_on_assigned_route(jj.id));
 when 'commercial_flows' then return private.has_any(u,array['jobs.view','jobs.manage','quotes.view','quotes.manage','customers.view','pr.receiving','pr.returns','pr.routes.plan','pr.routes.live','pr.reschedule']) or exists(select 1 from public.jobs jj where jj.flow_id=(row_data->>'id')::uuid and private.job_on_assigned_route(jj.id));
 when 'quotes','quote_items','agreements','accepted_documents','accepted_document_status' then return private.has_any(u,array['quotes.view','quotes.manage','jobs.view']);
 when 'policies' then return private.has_any(u,array['quotes.view','quotes.manage','settings.manage']);
 when 'documents' then
 if row_data->>'transaction_id' is not null or row_data->>'payment_request_id' is not null or row_data->>'type' in ('Receipt','Payment Receipt','Final Receipt','Refund Receipt') then return private.has_any(u,array['payments.view','payments.record']);end if;
 j:=(row_data->>'job_id')::uuid;
 if j is not null then return private.has_any(u,array['jobs.view','jobs.manage','production.work','pr.receiving','pr.returns','pr.routes.plan','pr.routes.live','pr.reschedule']) or (private.job_on_assigned_route(j) and row_data->>'type' in ('Receiving Evidence','Delivery Evidence') and exists(select 1 from public.pick_return_stops ss where ss.id=(row_data->>'pick_return_stop_id')::uuid and ss.job_id=j and private.route_visible(ss.route_id)));end if;
 if row_data->>'quote_id' is not null or row_data->>'agreement_id' is not null then return private.has_any(u,array['quotes.view','quotes.manage']);end if;
 return row_data->>'customer_id' is not null and private.has_block(u,'customers.view');
 when 'jobs','job_items','pick_return_orders','job_extensions','delivery_acknowledgments','cancellation_requests' then
 j:=case when table_key='jobs' then (row_data->>'id')::uuid else (row_data->>'job_id')::uuid end;
 return private.has_any(u,array['jobs.view','jobs.manage','production.work','pr.receiving','pr.returns','pr.routes.plan','pr.routes.live','pr.reschedule']) or private.job_on_assigned_route(j);
 when 'job_receipts','payment_requests','logistics_payment_attempts' then return private.has_any(u,array['payments.view','payments.record']);
 when 'route_compensations','refunds' then return private.has_any(u,array['payments.refund','payments.view']);
 when 'sales','sale_versions','collections','transactions','accounts','physical_accounts','expenses','owner_transactions','reimbursements','inter_unit_transfers','mileage','monthly_closes' then return private.has_block(u,'payments.view');
 when 'notifications' then return private.has_block(u,'settings.manage');
 when 'audit_log' then return (row_data->>'entity' in ('jobs','job_items','job_extensions') and private.has_block(u,'jobs.view')) or (row_data->>'entity' in ('quotes','quote_items') and private.has_block(u,'quotes.view'));
 when 'assets','vendors','categories' then return private.has_any(u,array['settings.manage','payments.view']);
 when 'storage_folders','document_relations' then return false;
 when 'delivery_attempt_fees' then return private.has_any(u,array['jobs.view','payments.view','payments.record']);
 when 'quote_logistics' then return private.has_any(u,array['jobs.view','quotes.view','quotes.manage']) or exists(select 1 from public.jobs jj where jj.quote_id=(row_data->>'quote_id')::uuid and private.job_on_assigned_route(jj.id));
 else return false;
 end case;
end$$;
-- Applied to every existing tenant table, including future migration additions by repeating this policy setup.
do $$declare t record;begin
 for t in select c.table_name from information_schema.columns c join information_schema.tables it using(table_schema,table_name) where c.table_schema='public' and c.column_name='unit_id' and it.table_type='BASE TABLE' and c.table_name not in ('memberships','roles','staff_access','user_roles') loop
 execute format('create policy rbac_tenant_restriction on public.%I as restrictive for all to authenticated using (private.rbac_row(%L,to_jsonb(%I))) with check (private.rbac_row(%L,to_jsonb(%I)))',t.table_name,t.table_name,t.table_name,t.table_name,t.table_name);
 end loop;
end$$;
create policy rbac_incidents_read on public.route_incidents for select to authenticated using(unit_id='10000000-0000-0000-0000-000000000002' and private.rbac_row('route_incidents',to_jsonb(route_incidents)));
create policy rbac_incident_jobs_read on public.route_incident_jobs for select to authenticated using(unit_id='10000000-0000-0000-0000-000000000002' and private.rbac_row('route_incident_jobs',to_jsonb(route_incident_jobs)));
create policy rbac_compensations_read on public.route_compensations for select to authenticated using(unit_id='10000000-0000-0000-0000-000000000002' and private.rbac_row('route_compensations',to_jsonb(route_compensations)));
create policy blocks_read on public.permission_blocks for select to authenticated using(private.staff_active('10000000-0000-0000-0000-000000000002'));
create policy roles_read on public.roles for select to authenticated using(private.is_owner(unit_id));
create policy role_blocks_read on public.role_blocks for select to authenticated using(exists(select 1 from public.roles r where r.id=role_id and private.is_owner(r.unit_id)));
create policy staff_access_read on public.staff_access for select to authenticated using(private.is_owner(unit_id) or user_id=auth.uid());
create policy user_roles_read on public.user_roles for select to authenticated using(private.is_owner(unit_id) or user_id=auth.uid());
-- Rewrite guard calls mechanically in CURRENT function bodies, never alter historical migrations.
-- Unexpected function language/definition causes a migration failure rather than skipping enforcement.
do $$declare f record;definition text;guard text;begin
 for f in select p.oid,p.proname,l.lanname from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang where n.nspname='public' and p.prokind='f' and pg_get_functiondef(p.oid) like '%private.require_admin(%' loop
 definition:=replace(pg_get_functiondef(f.oid),'private.require_admin(',format('private.require_rbac(%L,',f.proname));
 guard:='';
 if f.proname in ('pickup_driver_action','return_driver_action','advance_pick_return_stop','collect_route_cash','return_acknowledgment_link','verify_route_items') then guard:='perform private.require_stop(p_stop);';end if;
 if f.proname in ('depart_driver_route','driver_route_estimate_context','update_driver_route_estimates','route_live_channel','report_driver_incident','confirm_pick_return_route','route_item_checklist') then guard:='perform private.require_route(p_route);';end if;
 if f.proname='generate_job_receipt' then guard:='perform private.require_receipt_scope(p_job);';end if;
 if f.proname='confirm_payment_request' then guard:='perform private.require_cash_request(p_id);';end if;
 if f.proname='resolve_driver_incident' then guard:='perform private.require_route((select route_id from public.route_incidents where id=p_incident));';end if;
 if f.proname in ('verify_route_items','route_item_checklist') then guard:=guard||'if p_kind=''Returned'' and not private.has_block(''10000000-0000-0000-0000-000000000002'',''pr.returns'') then raise exception ''Shop Return verification required'' using errcode=''42501'';end if;';end if;
 if guard<>'' then
 if f.lanname<>'plpgsql' then raise exception 'Expected plpgsql: %',f.proname;end if;
 definition:=regexp_replace(definition,'\mbegin\M','begin '||guard,'i');
 end if;
 execute definition;
 end loop;
end$$;
do $$declare d text;begin
 select pg_get_functiondef('private.send_review(uuid,boolean)'::regprocedure) into d;
 d:=replace(d,'private.require_admin(', 'private.require_rbac(''send_quote_to'',');execute d;
end$$;
-- Document actions must validate both type and route/job binding, including retries/finalization.
create function private.require_evidence(p jsonb) returns void language plpgsql security definer set search_path='' as $$declare u uuid:=(p->>'unit_id')::uuid;s public.pick_return_stops;begin
 if auth.role()='service_role' or private.is_owner(u) then return;end if;
 if p->>'transaction_id' is not null or p->>'payment_request_id' is not null then raise exception 'Operational evidence cannot modify financial records' using errcode='42501';end if;
 if p->>'job_id' is not null and ((p->>'quote_id' is not null and not exists(select 1 from public.jobs jj where jj.id=(p->>'job_id')::uuid and jj.quote_id=(p->>'quote_id')::uuid)) or (p->>'customer_id' is not null and not exists(select 1 from public.jobs jj join public.commercial_flows ff on ff.id=jj.flow_id where jj.id=(p->>'job_id')::uuid and ff.customer_id=(p->>'customer_id')::uuid))) then raise exception 'Evidence relationships must match the Job' using errcode='42501';end if;
 if p->>'type'='Receiving Evidence' and private.has_block(u,'pr.receiving') then return;end if;
 if p->>'type'='Delivery Evidence' and private.has_block(u,'pr.returns') then return;end if;
 if p->>'type' in ('Preparation Evidence','Production Evidence','Completed Evidence','Finished Evidence') and private.has_block(u,'production.work') then return;end if;
 if p->>'type' in ('Issue / Review Evidence','Cancellation Evidence','Refund Review Evidence') and private.has_block(u,'jobs.manage') then return;end if;
 if p->>'type'='Payment screenshot' and private.has_block(u,'payments.record') then return;end if;
 if p->>'type' in ('Receiving Evidence','Delivery Evidence') and private.has_any(u,array['driver.routes','pr.routes.live']) then
 select * into s from public.pick_return_stops where id=(p->>'pick_return_stop_id')::uuid;
 if s.id is null or s.job_id is distinct from (p->>'job_id')::uuid or s.unit_id is distinct from u then raise exception 'Invalid route evidence' using errcode='42501';end if;perform private.require_stop(s.id);return;
 end if;
 raise exception 'Evidence permission required' using errcode='42501';
end$$;
do $$declare f record;d text;g text;begin
 for f in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('register_document_metadata','finish_document_storage','update_document_evidence_metadata') loop
 g:=case when f.proname='register_document_metadata' then 'perform private.require_evidence(p);' when f.proname='finish_document_storage' then 'perform private.require_evidence((select to_jsonb(rbac_doc) from public.documents rbac_doc where rbac_doc.id=p_id));' else 'perform private.require_evidence((select to_jsonb(rbac_doc) from public.documents rbac_doc where rbac_doc.id=p_document));' end;
 d:=regexp_replace(pg_get_functiondef(f.oid),'\mbegin\M','begin '||g,'i');execute d;
 end loop;
 -- Token-based customer scheduling remains untouched; staff actors require rescheduling permission.
 select pg_get_functiondef('private.route_actor(uuid,text)'::regprocedure) into d;
 d:=replace(d,'private.can_access(j.unit_id)','private.read_permission(j.unit_id,array[''pr.reschedule''])');execute d;
 -- Payment files keep capability access; staff membership alone is insufficient.
 select pg_get_functiondef('public.payment_proof_file(text,uuid,text)'::regprocedure) into d;
 d:=replace(d,'private.can_access(j.unit_id)','private.read_permission(j.unit_id,array[''payments.view'',''payments.record''])');execute d;
end$$;
-- Restrict otherwise membership-only read RPCs at their tenant predicate.
do $$declare f record;d text;keys text;begin
 for f in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('accepted_pdf_file','search_records','vehicle_report','dashboard_stats','customer_stats','job_lifecycle','customer_mail_status') loop
 keys:=case f.proname when 'accepted_pdf_file' then 'array[''quotes.view'',''jobs.view'']' when 'search_records' then 'array[''customers.view'']' when 'job_lifecycle' then 'array[''jobs.view'']' when 'customer_mail_status' then 'array[''settings.manage'']' else 'array[''payments.view'']' end;
 d:=regexp_replace(pg_get_functiondef(f.oid),'private.can_access\(([^()]*)\)','private.read_permission(\1,'||keys||')','g');execute d;
 end loop;
end$$;
-- Drivers need the exact cash balance without general ledger/table access.
create function public.driver_route_balances(p_route uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform private.require_route(p_route);
 return coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'balance_due',t.balance_due)) from public.job_commercial_totals t where exists(select 1 from public.pick_return_stops ss where ss.route_id=p_route and ss.job_id=t.id)),'[]');
end$$;
revoke all on function public.driver_route_balances(uuid) from public,anon;
grant execute on function public.driver_route_balances(uuid) to authenticated;
-- Search results honor each record's permission; a customer-view grant is not a ledger grant.
do $$declare d text;begin
 select pg_get_functiondef('public.search_records(uuid,text)'::regprocedure) into d;
 d:=replace(d,'q.unit_id=p_unit','q.unit_id=p_unit and (p_unit<>''10000000-0000-0000-0000-000000000002'' or private.has_block(p_unit,''quotes.view''))');
 d:=replace(d,'j.unit_id=p_unit','j.unit_id=p_unit and (p_unit<>''10000000-0000-0000-0000-000000000002'' or private.has_block(p_unit,''jobs.view''))');
 d:=replace(d,'s.unit_id=p_unit','s.unit_id=p_unit and (p_unit<>''10000000-0000-0000-0000-000000000002'' or private.has_block(p_unit,''payments.view''))');
 d:=replace(d,'d.unit_id=p_unit','d.unit_id=p_unit and private.rbac_row(''documents'',to_jsonb(d))');execute d;
end$$;
-- Never return a customer's acceptance capability to the route operator.
do $$declare d text;begin
 select pg_get_functiondef('public.advance_pick_return_stop(uuid,text)'::regprocedure) into d;
 d:=replace(d,'''completion_token'',completion_token', '''completion_token'',case when private.is_owner(j.unit_id) then completion_token else null end');execute d;
end$$;
create function private.evidence_storage_write(bucket text,path text) returns boolean language plpgsql stable security definer set search_path='' as $$declare d public.documents;begin
 if bucket<>'tooltag-files' then return false;end if;
 select dd.* into d from public.documents dd where dd.unit_id='10000000-0000-0000-0000-000000000002' and path=dd.unit_id::text||'/documents/'||dd.id::text||'/'||coalesce(dd.original_file_name,dd.file_name);
 if d.id is null or d.uploaded_by is distinct from auth.uid() then return false;end if;
 perform private.require_evidence(to_jsonb(d));return true;
 exception when insufficient_privilege then return false;
end$$;
create function private.require_storage_finalize(p_id uuid,p_bucket text,p_path text,p_status text) returns void language plpgsql security definer set search_path='' as $$declare d public.documents;begin
 select * into d from public.documents where id=p_id;
 if auth.role()='service_role' or private.is_owner(d.unit_id) then return;end if;
 if d.uploaded_by is distinct from auth.uid() then raise exception 'Only the uploader may finalize evidence' using errcode='42501';end if;
 if p_status='stored' and (not private.evidence_storage_write(p_bucket,p_path) or not exists(select 1 from storage.objects where bucket_id=p_bucket and name=p_path)) then raise exception 'Evidence file must be stored under its own document' using errcode='42501';end if;
end$$;
do $$declare d text;begin
 select pg_get_functiondef('public.finish_document_storage(uuid,text,text,text,text)'::regprocedure) into d;
 d:=regexp_replace(d,'\mbegin\M','begin perform private.require_storage_finalize(p_id,p_bucket,p_path,p_status);','i');execute d;
end$$;
-- Restrictive Storage gate prevents legacy membership policies leaking proof/evidence.
create function private.rbac_storage(bucket text,path text) returns boolean language plpgsql stable security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';begin
 if split_part(path,'/',1)<>u::text then return true;end if;
 if bucket not in ('quote-images','payment-proofs','tooltag-files') then return false;end if;
 if private.is_owner(u) then return true;end if;
 if bucket='quote-images' then return private.has_any(u,array['quotes.view','quotes.manage','jobs.view']);end if;
 if bucket='payment-proofs' then return private.has_any(u,array['payments.view','payments.record']);end if;
 if bucket='tooltag-files' then return private.evidence_storage_write(bucket,path) or exists(select 1 from public.documents d where d.storage_path=path and private.rbac_row('documents',to_jsonb(d)));end if;
 return false;
end$$;
create policy rbac_storage_read on storage.objects as restrictive for select to authenticated using(private.rbac_storage(bucket_id,name));
-- Authenticated direct storage writes remain Owner-only except quote images for quote managers.
create policy rbac_storage_insert on storage.objects as restrictive for insert to authenticated with check(split_part(name,'/',1)<>'10000000-0000-0000-0000-000000000002' or private.is_owner('10000000-0000-0000-0000-000000000002') or (bucket_id='quote-images' and private.has_block('10000000-0000-0000-0000-000000000002','quotes.manage')) or private.evidence_storage_write(bucket_id,name));
create policy rbac_storage_update on storage.objects as restrictive for update to authenticated using(split_part(name,'/',1)<>'10000000-0000-0000-0000-000000000002' or private.is_owner('10000000-0000-0000-0000-000000000002') or private.evidence_storage_write(bucket_id,name)) with check(split_part(name,'/',1)<>'10000000-0000-0000-0000-000000000002' or private.is_owner('10000000-0000-0000-0000-000000000002') or private.evidence_storage_write(bucket_id,name));
create policy rbac_storage_delete on storage.objects as restrictive for delete to authenticated using(split_part(name,'/',1)<>'10000000-0000-0000-0000-000000000002' or private.is_owner('10000000-0000-0000-0000-000000000002'));
create policy rbac_evidence_insert on storage.objects for insert to authenticated with check(private.evidence_storage_write(bucket_id,name));
create policy rbac_evidence_update on storage.objects for update to authenticated using(private.evidence_storage_write(bucket_id,name)) with check(private.evidence_storage_write(bucket_id,name));
-- A custom quote manager may upload through the existing private image bucket.
create policy rbac_quote_image_insert on storage.objects for insert to authenticated with check(bucket_id='quote-images' and split_part(name,'/',1)='10000000-0000-0000-0000-000000000002' and private.has_block('10000000-0000-0000-0000-000000000002','quotes.manage'));
do $$declare t text;begin foreach t in array array['pick_return_routes','pick_return_stops'] loop
 if not exists(select 1 from pg_trigger tr join pg_class c on c.oid=tr.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=t and tr.tgfoid='private.audit_change()'::regprocedure) then execute format('create trigger rbac_route_audit after insert or update on public.%I for each row execute function private.audit_change()',t);end if;
end loop;end$$;
-- New Owners use viewer legacy memberships; their authority comes exclusively from RBAC.
create policy rbac_storage_member_read on storage.objects for select to authenticated using(split_part(name,'/',1)='10000000-0000-0000-0000-000000000002' and private.rbac_storage(bucket_id,name));
create policy rbac_storage_owner_insert on storage.objects for insert to authenticated with check(bucket_id in ('tooltag-files','quote-images','payment-proofs') and split_part(name,'/',1)='10000000-0000-0000-0000-000000000002' and private.is_owner('10000000-0000-0000-0000-000000000002'));
create policy rbac_storage_owner_update on storage.objects for update to authenticated using(bucket_id in ('tooltag-files','quote-images','payment-proofs') and split_part(name,'/',1)='10000000-0000-0000-0000-000000000002' and private.is_owner('10000000-0000-0000-0000-000000000002')) with check(bucket_id in ('tooltag-files','quote-images','payment-proofs') and split_part(name,'/',1)='10000000-0000-0000-0000-000000000002' and private.is_owner('10000000-0000-0000-0000-000000000002'));
create policy rbac_storage_owner_delete on storage.objects for delete to authenticated using(bucket_id in ('tooltag-files','quote-images','payment-proofs') and split_part(name,'/',1)='10000000-0000-0000-0000-000000000002' and private.is_owner('10000000-0000-0000-0000-000000000002'));
-- No public execute grants on new definer helpers. Policies need authenticated execute only.
revoke all on function private.staff_active(uuid),private.is_owner(uuid),private.has_block(uuid,text),private.has_any(uuid,text[]),private.read_permission(uuid,text[]),private.require_owner(uuid),private.route_visible(uuid),private.job_on_assigned_route(uuid),private.require_route(uuid),private.require_stop(uuid),private.rbac_log(text,uuid,jsonb),private.rbac_action_blocks(text),private.require_rbac(text,uuid),private.rbac_row(text,jsonb),private.require_evidence(jsonb),private.require_cash_request(uuid),private.require_receipt_scope(uuid),private.rbac_storage(text,text),private.evidence_storage_write(text,text),private.require_storage_finalize(uuid,text,text,text) from public,anon,authenticated;
grant execute on function private.staff_active(uuid),private.is_owner(uuid),private.has_block(uuid,text),private.has_any(uuid,text[]),private.route_visible(uuid),private.rbac_row(text,jsonb),private.rbac_storage(text,text),private.evidence_storage_write(text,text) to authenticated;
revoke all on function public.staff_permissions(),public.rbac_directory(),public.rbac_save_role(uuid,text,text[]),public.rbac_save_user(uuid,text,boolean,uuid[]),public.rbac_log_credential_reset(uuid),public.assign_route_operator(uuid,uuid),public.route_operators() from public,anon;
grant execute on function public.staff_permissions(),public.rbac_directory(),public.rbac_save_role(uuid,text,text[]),public.rbac_save_user(uuid,text,boolean,uuid[]),public.rbac_log_credential_reset(uuid),public.assign_route_operator(uuid,uuid),public.route_operators() to authenticated;
commit;
