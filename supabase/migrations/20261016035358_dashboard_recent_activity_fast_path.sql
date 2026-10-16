-- Check the Owner once before grouping audit rows, instead of repeating session/RBAC
-- checks for every audit field through the security-invoker activity view.
begin;
create function private.dashboard_recent_activity(p_unit uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or p_unit is distinct from '10000000-0000-0000-0000-000000000002'::uuid or not private.is_owner(p_unit) then
  raise exception 'Owner access required' using errcode='42501';
 end if;
 return coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc,a.id desc)
  from (select id,unit_id,entity,entity_id,actor_id,created_at,changed_fields
        from public.recent_activity where unit_id=p_unit
        order by created_at desc,id desc limit 10) a),'[]'::jsonb);
end$$;
-- The exposed wrapper has no elevated privileges. The guarded helper is private.
create function public.dashboard_recent_activity(p_unit uuid) returns jsonb
language sql stable security invoker set search_path='' as $$select private.dashboard_recent_activity(p_unit)$$;
revoke all on function private.dashboard_recent_activity(uuid),public.dashboard_recent_activity(uuid) from public,anon;
grant execute on function private.dashboard_recent_activity(uuid),public.dashboard_recent_activity(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
