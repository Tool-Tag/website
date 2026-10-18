begin;
alter table public.support_conversations add column job_context jsonb;
alter table public.support_conversations add column status_request_id uuid unique;
create function public.submit_status_support(p_token text,p_request uuid,p_message text) returns text
language plpgsql security definer set search_path='' as $$
declare j public.jobs;c public.customers;recipient text;cid uuid;code text;context jsonb;begin
 select jobs.* into j from private.job_status_links l join public.jobs jobs on jobs.id=l.job_id
 where l.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and jobs.unit_id='10000000-0000-0000-0000-000000000002';
 if j.id is null then raise exception 'Status link unavailable';end if;
 if p_request is null or length(trim(coalesce(p_message,''))) not between 1 and 10000 then raise exception 'Enter a message of up to 10,000 characters';end if;
 perform pg_advisory_xact_lock(hashtext('status-support:'||j.id));
 select id,case_code into cid,code from public.support_conversations where status_request_id=p_request and job_id=j.id;
 if cid is not null then return code;end if;
 if (select count(*) from public.support_conversations where job_id=j.id and status_request_id is not null and created_at>now()-interval '1 day')>=5 then raise exception 'Too many inquiries. Please reply to your existing Support email.';end if;
 select customers.* into c from public.customers join public.commercial_flows f on f.customer_id=customers.id where f.id=j.flow_id;
 select customer_recipient_email into recipient from public.accepted_documents where job_id=j.id order by accepted_at desc limit 1;
 recipient:=coalesce(nullif(recipient,''),nullif(c.email,''),nullif(c.company_email,''));
 if recipient is null then raise exception 'No project email is available. Please contact ToolTag directly.';end if;
 context:=jsonb_build_object('captured_at',now(),'job',to_jsonb(j),'customer',jsonb_build_object('id',c.id,'name',c.name,'email',recipient),
 'quote',(select to_jsonb(q) from public.quotes q where q.id=j.quote_id),
 'items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.job_items i where i.job_id=j.id),
 'logistics',(select to_jsonb(o) from public.pick_return_orders o where o.job_id=j.id),
 'documents',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.file_name,'type',d.type,'status',d.status)),'[]') from public.documents d where d.job_id=j.id));
 code:=private.next_support_code();
 insert into public.support_conversations(unit_id,mailbox,sender_email,sender_name,subject,customer_id,case_code,status,origin,channel,job_id,job_reference,contact_phone,job_context,status_request_id)
 values(j.unit_id,'support',recipient,c.name,'Help with '||j.code,c.id,code,'Open','Job','Email',j.id,j.code,c.phone,context,p_request) returning id into cid;
 insert into public.support_messages(conversation_id,direction,sender_email,subject,body) values(cid,'Inbound',recipient,'Help with '||j.code,trim(p_message));
 return code;
end$$;
revoke all on function public.submit_status_support(text,uuid,text) from public;
grant execute on function public.submit_status_support(text,uuid,text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
