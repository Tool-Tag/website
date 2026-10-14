begin;
alter table public.support_conversations add column origin text not null default 'Inbox' check(origin in ('Inbox','Job'));
alter table public.support_conversations add column channel text not null default 'Email' check(channel in ('Email','Call','Job'));
alter table public.support_conversations add column job_id uuid references public.jobs(id);
alter table public.support_conversations add column request_key uuid unique;
alter table public.support_conversations add column closure_final_message_id uuid references public.support_messages(id);
alter table public.support_conversations add column closure_confirmed_by uuid references auth.users(id);
create index support_job_link on public.support_conversations(job_id);
create function private.next_support_code() returns text language plpgsql security definer set search_path='' as $$declare y integer:=extract(year from now() at time zone 'America/Denver');n integer;begin
 insert into private.support_case_counter values(y,1) on conflict(year) do update set value=support_case_counter.value+1 returning value into n;
 return 'TT-C-'||y||'-'||lpad(n::text,greatest(5,length(n::text)),'0');
end$$;
create function private.capture_job_support(p_job uuid) returns uuid language plpgsql security definer set search_path='' as $$declare j public.jobs;c public.customers;cid uuid;begin
 select * into j from public.jobs where id=p_job and unit_id='10000000-0000-0000-0000-000000000002';
 if j.id is null or j.status<>'Issue / Review' then return null;end if;
 select cust.* into c from public.customers cust join public.commercial_flows f on f.customer_id=cust.id where f.id=j.flow_id;
 select id into cid from public.support_conversations where job_id=j.id and origin='Job' and status<>'Closed' order by created_at desc limit 1;
 if cid is not null then return cid;end if;
 c.email:=coalesce((select recipient from private.quote_delivery where quote_id=j.quote_id),c.email);
 insert into public.support_conversations(unit_id,mailbox,sender_email,sender_name,subject,customer_id,case_code,status,origin,channel,job_id)
 values(j.unit_id,'support',coalesce(c.email,''),c.name,'Issue reported · '||j.code,c.id,private.next_support_code(),'Open','Job','Job',j.id) returning id into cid;
 insert into public.support_messages(conversation_id,direction,sender_email,subject,body,sent_at)
 values(cid,'Inbound',coalesce(c.email,''),'Issue reported · '||j.code,coalesce(nullif(j.completion_reason,''),'The customer reported an issue with this Job.'),coalesce(j.issue_reported_at,j.updated_at));return cid;
end$$;
create function private.job_support_case_trigger() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.unit_id='10000000-0000-0000-0000-000000000002' and new.status='Issue / Review' and (tg_op='INSERT' or old.status is distinct from new.status) then perform private.capture_job_support(new.id);end if;return new;
end$$;
create trigger job_support_case after insert or update of status on public.jobs for each row execute function private.job_support_case_trigger();
select private.capture_job_support(id) from public.jobs where unit_id='10000000-0000-0000-0000-000000000002' and status='Issue / Review' and not is_lost;
create function public.support_create_case(p_request uuid,p_customer uuid,p_job uuid,p_subject text,p_body text) returns uuid language plpgsql security definer set search_path='' as $$declare c public.customers;cid uuid;begin
 perform private.require_support();
 if p_request is null or length(trim(p_subject)) not between 1 and 500 or length(trim(p_body)) not between 1 and 20000 then raise exception 'Customer, subject and call details are required';end if;
 select id into cid from public.support_conversations where request_key=p_request and unit_id='10000000-0000-0000-0000-000000000002';if cid is not null then return cid;end if;
 select * into c from public.customers where id=p_customer and unit_id='10000000-0000-0000-0000-000000000002';if c.id is null then raise exception 'Customer unavailable';end if;
 if p_job is not null and not exists(select 1 from public.jobs j join public.commercial_flows f on f.id=j.flow_id where j.id=p_job and j.unit_id=c.unit_id and f.customer_id=c.id) then raise exception 'Choose a Job belonging to this customer';end if;
 insert into public.support_conversations(unit_id,mailbox,sender_email,sender_name,subject,customer_id,case_code,status,channel,job_id,request_key)
 values(c.unit_id,'support',coalesce(c.email,''),c.name,trim(p_subject),c.id,private.next_support_code(),'Open','Call',p_job,p_request) returning id into cid;
 insert into public.support_messages(conversation_id,direction,sender_email,subject,body,actor_id) values(cid,'Inbound',coalesce(c.email,''),trim(p_subject),trim(p_body),auth.uid());
 perform private.rbac_log('support.call.created',cid,jsonb_build_object('job',p_job));return cid;
end$$;
create or replace function public.support_close(p_id uuid) returns void language plpgsql security definer set search_path='' as $$declare c public.support_conversations;begin
 perform private.require_support();select * into c from public.support_conversations where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' for update;
 if c.id is null then raise exception 'Case unavailable';end if;
 if exists(select 1 from public.support_messages where conversation_id=p_id and delivery_status in ('Sending','Unknown')) then raise exception 'Verify the pending reply before resolving';end if;
 if c.unread_count>0 then raise exception 'Read the latest message before resolving';end if;
 if c.closure_final_message_id is null or not exists(select 1 from public.support_messages where id=c.closure_final_message_id and conversation_id=c.id and delivery_status='Sent') then raise exception 'Complete the closure protocol before resolving';end if;
 update public.support_conversations set status='Closed',closed_at=now(),unread_count=0,case_code=case when mailbox='hello' then case_code else coalesce(case_code,private.next_support_code()) end where id=p_id;
 if c.origin='Job' then update public.jobs set issue_response_at=coalesce(issue_response_at,now()),issue_responded_by=coalesce(issue_responded_by,auth.uid()) where id=c.job_id;end if;
 perform private.rbac_log('support.case.resolved',p_id);
end$$;
create function private.support_response_to_job() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.direction='Outbound' and new.delivery_status='Sent' and old.delivery_status is distinct from 'Sent' then
 update public.jobs j set issue_response_at=new.sent_at,issue_responded_by=new.actor_id from public.support_conversations c where c.id=new.conversation_id and c.origin='Job' and c.job_id=j.id and j.unit_id=c.unit_id and j.issue_reported_at<=new.sent_at;
 end if;return new;end$$;
create trigger support_response_to_job after update of delivery_status on public.support_messages for each row execute function private.support_response_to_job();
-- Use the existing attention RPC, removing duplicate Job obligations now represented by a case.
do $$declare definition text;begin
 select pg_get_functiondef('public.urgent_login_attention()'::regprocedure) into definition;
 definition:=replace(definition,'/app/notifications','/app/support');
 definition:=replace(definition,'clock.started_at is not null and','clock.started_at is not null and not exists(select 1 from public.jobs answered where c.origin=''Job'' and answered.id=c.job_id and answered.issue_response_at>=clock.started_at) and');
 definition:=replace(definition,'j.issue_response_at is null and','j.issue_response_at is null and not exists(select 1 from public.support_conversations linked where linked.job_id=j.id and linked.origin=''Job'') and');
 execute definition;
end$$;
revoke all on function private.next_support_code(),private.capture_job_support(uuid),private.job_support_case_trigger(),private.support_response_to_job() from public,anon,authenticated;
revoke all on function public.support_create_case(uuid,uuid,uuid,text,text) from public,anon;
grant execute on function public.support_create_case(uuid,uuid,uuid,text,text) to authenticated;
create function public.support_directory() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform private.require_support();return jsonb_build_object('customers',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'email',email) order by name),'[]') from public.customers where unit_id='10000000-0000-0000-0000-000000000002'),'jobs',(select coalesce(jsonb_agg(jsonb_build_object('id',j.id,'code',j.code,'customer_id',f.customer_id) order by j.code desc),'[]') from public.jobs j join public.commercial_flows f on f.id=j.flow_id where j.unit_id='10000000-0000-0000-0000-000000000002'));
end$$;
revoke all on function public.support_directory() from public,anon;grant execute on function public.support_directory() to authenticated;
create function public.support_cases() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform private.require_support();
 return coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('last_message',m.body,'last_message_at',m.sent_at,'waiting_since',case when c.status<>'Closed' and inbound.sent_at>greatest(coalesce(outbound.sent_at,'-infinity'::timestamptz),coalesce(case when c.origin='Job' then j.issue_response_at end,'-infinity'::timestamptz)) then inbound.sent_at end))
 from public.support_conversations c left join public.jobs j on j.id=c.job_id
 left join lateral(select body,sent_at from public.support_messages where conversation_id=c.id order by sent_at desc,id desc limit 1) m on true
 left join lateral(select max(sent_at) sent_at from public.support_messages where conversation_id=c.id and direction='Inbound') inbound on true
 left join lateral(select max(sent_at) sent_at from public.support_messages where conversation_id=c.id and direction='Outbound' and delivery_status='Sent') outbound on true
 where c.unit_id='10000000-0000-0000-0000-000000000002'),'[]'::jsonb);
end$$;
revoke all on function public.support_cases() from public,anon;grant execute on function public.support_cases() to authenticated;
create function public.support_resolve_protocol(p_id uuid,p_final uuid) returns void language plpgsql security definer set search_path='' as $$declare c public.support_conversations;m public.support_messages;begin
 perform private.require_support();select * into c from public.support_conversations where id=p_id and unit_id='10000000-0000-0000-0000-000000000002' for update;
 if c.id is null then raise exception 'Case unavailable';end if;if c.status='Closed' and c.closure_final_message_id=p_final then return;end if;
 select * into m from public.support_messages where id=p_final and conversation_id=c.id and direction='Outbound' and delivery_status='Sent';
 if m.id is null or m.body not like 'It was a pleasure helping you.%' then raise exception 'The final closure message must be successfully sent';end if;
 if exists(select 1 from public.support_messages where conversation_id=c.id and direction='Inbound' and sent_at>m.sent_at) then raise exception 'A new customer message needs review before closing';end if;
 update public.support_conversations set closure_final_message_id=p_final,closure_confirmed_by=auth.uid() where id=c.id;
 perform public.support_close(c.id);perform private.rbac_log('support.closure.protocol.confirmed',c.id,jsonb_build_object('final_message',p_final,'customer_declined_further_help',true));
end$$;
create function private.support_reopen_protocol() returns trigger language plpgsql set search_path='' as $$begin
 if old.status='Closed' and new.status<>'Closed' then new.closure_final_message_id:=null;new.closure_confirmed_by:=null;end if;return new;end$$;
create trigger support_reopen_protocol before update of status on public.support_conversations for each row execute function private.support_reopen_protocol();
revoke all on function public.support_resolve_protocol(uuid,uuid) from public,anon;grant execute on function public.support_resolve_protocol(uuid,uuid) to authenticated;
revoke all on function private.support_reopen_protocol() from public,anon,authenticated;
-- Hello inquiries retain threading and actor signatures without case numbering.
do $$declare definition text;begin
 select pg_get_functiondef('public.support_prepare_reply(uuid,uuid,text)'::regprocedure) into definition;
 definition:=replace(definition,'if c.case_code is null then','if c.case_code is null and c.mailbox<>''hello'' then');
 definition:=replace(definition,$match$'['||c.case_code||'] Re: '$match$,$replacement$(case when c.mailbox='hello' then 'Re: ' else '['||c.case_code||'] Re: ' end)$replacement$);
 execute definition;
end$$;
commit;

