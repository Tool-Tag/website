begin;
-- Login age comes from Auth, never from a browser timestamp or JWT refresh time.
create function private.staff_session_deadline() returns timestamptz
language sql stable security definer set search_path='' as $$
 select s.created_at + interval '4 hours' from auth.sessions s
 where s.user_id=auth.uid() and s.id=coalesce(
 nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'session_id',
 nullif(current_setting('request.jwt.claim.session_id',true),''))::uuid
$$;
revoke all on function private.staff_session_deadline() from public,anon,authenticated;
create function public.staff_session_state() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('expires_at',d,'server_now',now(),'active',coalesce(d>now(),false),'session_id',coalesce(
 nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'session_id',
 nullif(current_setting('request.jwt.claim.session_id',true),'')))
 from (select private.staff_session_deadline() d) x
$$;
revoke all on function public.staff_session_state() from public,anon;
grant execute on function public.staff_session_state() to authenticated;
-- Central RBAC predicate protects authenticated RPCs and RLS after the deadline.
create or replace function private.staff_active(u uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select (u<>'10000000-0000-0000-0000-000000000002' or coalesce(private.staff_session_deadline()>now(),false))
 and exists(select 1 from public.staff_access where unit_id=u and user_id=auth.uid() and active)
 and exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid())
$$;

-- Store the start of each Job issue cycle independently of unrelated updates.
alter table public.jobs add column issue_reported_at timestamptz;
alter table public.jobs add column issue_response_at timestamptz;
alter table public.jobs add column issue_responded_by uuid references auth.users(id);
create function private.track_issue_response_clock() returns trigger language plpgsql set search_path='' as $$begin
 if new.unit_id='10000000-0000-0000-0000-000000000002' and new.status='Issue / Review' and (tg_op='INSERT' or old.status is distinct from new.status) then
 new.issue_reported_at:=now();new.issue_response_at:=null;new.issue_responded_by:=null;
 end if;return new;end$$;
create trigger track_issue_response_clock before insert or update of status on public.jobs for each row execute function private.track_issue_response_clock();
-- Existing active issues retain their last known transition time; no notifications replay.
update public.jobs set issue_reported_at=updated_at where unit_id='10000000-0000-0000-0000-000000000002' and status='Issue / Review';
create function private.urgent_login_allowed() returns boolean language sql stable security definer set search_path='' as $$
 select private.staff_active('10000000-0000-0000-0000-000000000002') and (
 private.is_owner('10000000-0000-0000-0000-000000000002') or exists(
 select 1 from public.user_roles ur join public.roles r on r.id=ur.role_id and r.unit_id=ur.unit_id
 where ur.user_id=auth.uid() and ur.unit_id='10000000-0000-0000-0000-000000000002' and lower(trim(r.name))='manager'))
$$;
revoke all on function private.urgent_login_allowed() from public,anon,authenticated;
create function public.urgent_login_attention() returns jsonb language plpgsql stable security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';begin
 if not private.staff_active(u) then return jsonb_build_object('eligible',false,'items','[]'::jsonb);end if;
 return jsonb_build_object('eligible',private.urgent_login_allowed(),'items',coalesce((select jsonb_agg(to_jsonb(x)) from (
 select 'refund'::text kind,r.id,j.code label,'/app/refunds'::text href,r.requested_at started_at
 from public.refund_requests r join public.jobs j on j.id=r.job_id where r.unit_id=u and r.status='Pending' and r.amount>r.processed_amount and (private.urgent_login_allowed() or private.has_any(u,array['payments.refund','payments.view']))
 union all
 select 'problem',c.id,coalesce(c.case_code,c.subject),'/app/notifications',clock.started_at
 from public.support_conversations c cross join lateral (
 select max(m.sent_at) started_at from public.support_messages m where m.conversation_id=c.id and m.direction='Inbound'
 and m.sent_at>coalesce((select max(o.sent_at) from public.support_messages o where o.conversation_id=c.id and o.direction='Outbound' and o.delivery_status='Sent'),'-infinity'::timestamptz)
 ) clock where c.unit_id=u and c.status<>'Closed' and clock.started_at is not null and (private.urgent_login_allowed() or private.has_block(u,'support.inbox'))
 union all
 select 'problem',j.id,j.code,'/app/jobs/'||j.id,j.issue_reported_at from public.jobs j where j.unit_id=u and j.status='Issue / Review' and not j.is_lost and j.issue_response_at is null and (private.urgent_login_allowed() or private.has_block(u,'jobs.view'))
 union all
 select 'lost',l.id,j.code,'/app/lost',l.reported_at from public.lost_jobs l join public.jobs j on j.id=l.job_id where j.unit_id=u and j.is_lost and (private.urgent_login_allowed() or private.has_any(u,array['jobs.view','pr.returns']))
 ) x),'[]'::jsonb));
end$$;
create function public.record_issue_response(p_job uuid) returns void language plpgsql security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';begin
 if not private.has_block(u,'jobs.manage') then raise exception 'Permission denied';end if;
 update public.jobs set issue_response_at=now(),issue_responded_by=auth.uid() where id=p_job and unit_id=u and status='Issue / Review' and issue_response_at is null;
 if found then insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,new_value) values(u,auth.uid(),'jobs',p_job,'Customer issue response recorded',jsonb_build_object('response_confirmed',true));end if;
end$$;
revoke all on function public.urgent_login_attention(),public.record_issue_response(uuid) from public,anon;
grant execute on function public.urgent_login_attention(),public.record_issue_response(uuid) to authenticated;
commit;
