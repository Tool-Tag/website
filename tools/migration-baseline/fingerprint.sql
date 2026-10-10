WITH ns AS (SELECT oid,nspname,nspowner,nspacl FROM pg_namespace WHERE nspname IN ('public','private')),
rel AS (SELECT c.*,n.nspname FROM pg_class c JOIN ns n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p','v','m','S')),
objects AS (
SELECT 'schemas' AS kind,nspname AS key,jsonb_build_object('owner',pg_get_userbyid(nspowner),'privileges',(SELECT jsonb_agg(jsonb_build_array(pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type) FROM aclexplode(coalesce(nspacl,acldefault('n',nspowner))) a)) AS value FROM ns
UNION ALL
SELECT 'relations',nspname||'.'||relname,jsonb_build_object('kind',relkind,'owner',pg_get_userbyid(relowner),'rls',relrowsecurity,'force_rls',relforcerowsecurity,'options',reloptions,'view',CASE WHEN relkind IN ('v','m') THEN pg_get_viewdef(oid,false) END) FROM rel
UNION ALL
SELECT 'columns',r.nspname||'.'||r.relname||'.'||a.attname,jsonb_build_object('position',a.attnum,'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,'default',pg_get_expr(d.adbin,d.adrelid),'collation',CASE WHEN a.attcollation<>0 THEN a.attcollation::regcollation::text END) FROM pg_attribute a JOIN rel r ON r.oid=a.attrelid LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attnum>0 AND NOT a.attisdropped
UNION ALL
SELECT 'constraints',r.nspname||'.'||r.relname||'.'||c.conname,jsonb_build_object('definition',pg_get_constraintdef(c.oid,false),'validated',c.convalidated,'deferrable',c.condeferrable,'deferred',c.condeferred) FROM pg_constraint c JOIN rel r ON r.oid=c.conrelid
UNION ALL
SELECT 'indexes',n.nspname||'.'||r.relname,jsonb_build_object('definition',pg_get_indexdef(i.indexrelid),'valid',i.indisvalid,'ready',i.indisready) FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN ns n ON n.oid=c.relnamespace JOIN pg_class r ON r.oid=i.indexrelid
UNION ALL
SELECT 'functions',n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',jsonb_build_object('definition',pg_get_functiondef(p.oid),'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,'config',p.proconfig,'volatility',p.provolatile,'parallel',p.proparallel) FROM pg_proc p JOIN ns n ON n.oid=p.pronamespace WHERE p.prokind IN ('f','p')
UNION ALL
SELECT 'triggers',r.nspname||'.'||r.relname||'.'||t.tgname,jsonb_build_object('definition',pg_get_triggerdef(t.oid,false),'enabled',t.tgenabled) FROM pg_trigger t JOIN rel r ON r.oid=t.tgrelid WHERE NOT t.tgisinternal
UNION ALL
SELECT 'policies',p.schemaname||'.'||p.tablename||'.'||p.policyname,jsonb_build_object('permissive',p.permissive,'roles',p.roles,'command',p.cmd,'using',p.qual,'check',p.with_check) FROM pg_policies p WHERE p.schemaname IN ('public','private','storage')
UNION ALL
SELECT 'relation_grants',r.nspname||'.'||r.relname||'.'||CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END||'.'||a.privilege_type,jsonb_build_object('grantor',pg_get_userbyid(a.grantor),'grantable',a.is_grantable) FROM rel r CROSS JOIN LATERAL aclexplode(coalesce(r.relacl,acldefault(CASE WHEN r.relkind='S' THEN 'S' ELSE 'r' END::"char",r.relowner))) a
UNION ALL
SELECT 'function_grants',n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||').' ||CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END||'.'||a.privilege_type,jsonb_build_object('grantor',pg_get_userbyid(a.grantor),'grantable',a.is_grantable) FROM pg_proc p JOIN ns n ON n.oid=p.pronamespace CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
UNION ALL
SELECT 'default_privileges',n.nspname||'.'||pg_get_userbyid(d.defaclrole)||'.'||d.defaclobjtype::text||'.'||CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END||'.'||a.privilege_type,jsonb_build_object('grantor',pg_get_userbyid(a.grantor),'grantable',a.is_grantable) FROM pg_default_acl d JOIN ns n ON n.oid=d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) a
UNION ALL
SELECT 'types',n.nspname||'.'||t.typname,jsonb_build_object('kind',t.typtype,'base',format_type(t.typbasetype,t.typtypmod),'enum',(SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid=t.oid),'owner',pg_get_userbyid(t.typowner)) FROM pg_type t JOIN ns n ON n.oid=t.typnamespace WHERE t.typtype IN ('e','d')
UNION ALL
SELECT 'extensions',e.extname,jsonb_build_object('version',e.extversion,'schema',n.nspname) FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
)
SELECT jsonb_object_agg(kind,entries) FROM (SELECT kind,jsonb_object_agg(key,value ORDER BY key) entries FROM objects GROUP BY kind) s;
