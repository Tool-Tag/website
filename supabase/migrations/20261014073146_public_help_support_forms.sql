begin;
alter table public.support_conversations add column contact_phone text;
alter table public.support_conversations add column job_reference text;
create table private.help_submissions (
 request_id uuid primary key,mailbox text not null,network_hash text not null,email text not null,payload_hash text not null,
 conversation_id uuid references public.support_conversations(id),created_at timestamptz not null default now(),
 sms_opt_in boolean not null default false,policies_accepted boolean not null default false,
 sms_disclosure text,policy_disclosure text
);
alter table private.help_submissions enable row level security;
revoke all on private.help_submissions from public,anon,authenticated;
create function public.submit_help_message(p_request uuid,p_network text,p_hash text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$declare u uuid:='10000000-0000-0000-0000-000000000002';s private.help_submissions;cid uuid;customer uuid;job uuid;matches integer;mailbox text:=p->>'mailbox';v_email text:=lower(trim(p->>'email'));ref text:=trim(coalesce(p->>'job',''));begin
 perform private.require_support_worker();
 if p_request is null or p_network!~'^[a-f0-9]{64}$' or p_hash!~'^[a-f0-9]{64}$' or mailbox not in ('support','hello') or length(trim(p->>'name')) not between 1 and 150 or v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(v_email)>254 or length(trim(p->>'message')) not between 1 and 20000 or length(coalesce(p->>'phone',''))>30 or length(ref)>80 then raise exception 'Invalid help request';end if;
 perform pg_advisory_xact_lock(hashtext('help:'||p_request));
 select * into s from private.help_submissions where request_id=p_request;
 if s.request_id is not null then if s.payload_hash<>p_hash then raise exception 'Request already submitted';end if;return jsonb_build_object('reference',coalesce((select case_code from public.support_conversations where id=s.conversation_id),'Message received'));end if;
 perform pg_advisory_xact_lock(hashtext('help-network:'||p_network));perform pg_advisory_xact_lock(hashtext('help-email:'||v_email));
 if (select count(*) from private.help_submissions where network_hash=p_network and created_at>now()-interval '1 hour')>=5 or (select count(*) from private.help_submissions where email=v_email and created_at>now()-interval '1 day')>=5 then raise exception 'Request rate limit';end if;
 select count(*),(array_agg(id))[1] into matches,customer from public.customers where unit_id=u and (lower(customers.email)=v_email or lower(company_email)=v_email);
 if matches<>1 then customer:=null;end if;
 -- A public Job number is not proof of ownership. Link only when its customer email matches.
 if mailbox='support' and customer is not null and ref<>'' then
 select j.id into job from public.jobs j join public.commercial_flows f on f.id=j.flow_id where j.unit_id=u and j.code=ref and f.customer_id=customer;
 end if;
 insert into public.support_conversations(unit_id,mailbox,sender_email,sender_name,subject,customer_id,job_id,contact_phone,job_reference,channel)
 values(u,mailbox,v_email,trim(p->>'name'),case when mailbox='hello' then 'Question from Help' else 'Support request from Help' end,customer,job,nullif(trim(p->>'phone'),''),case when mailbox='support' then nullif(ref,'') end,'Email') returning id into cid;
 insert into public.support_messages(conversation_id,direction,sender_email,subject,body) values(cid,'Inbound',v_email,case when mailbox='hello' then 'Question from Help' else 'Support request from Help' end,trim(p->>'message'));
 insert into private.help_submissions(request_id,mailbox,network_hash,email,payload_hash,conversation_id,sms_opt_in,policies_accepted,sms_disclosure,policy_disclosure)
 values(p_request,mailbox,p_network,v_email,p_hash,cid,coalesce((p->>'sms_opt_in')::boolean,false),coalesce((p->>'policies_accepted')::boolean,false),p->>'sms_disclosure',p->>'policy_disclosure');
 return jsonb_build_object('reference',coalesce((select case_code from public.support_conversations where id=cid),'Message received'));
end$$;
revoke all on function public.submit_help_message(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.submit_help_message(uuid,text,text,jsonb) to service_role;
commit;
