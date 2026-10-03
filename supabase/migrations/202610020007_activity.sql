create view public.recent_activity with(security_invoker=true) as
 select min(id::text)::uuid as id,unit_id,entity,entity_id,actor_id,created_at,
 string_agg(field,', ' order by field) as changed_fields
 from public.audit_log where field not in ('id','unit_id','created_at','updated_at')
 group by unit_id,entity,entity_id,actor_id,created_at;
grant select on public.recent_activity to authenticated;
revoke all on public.recent_activity from anon;
