-- Read-only inventory of the existing TEST seed. No messages, payments or jobs are created.
select j.code,c.name,c.phone,j.status,j.work_stage,
 pr.service_method,pr.pickup_status,pr.return_status
from public.jobs j
join public.commercial_flows f on f.id=j.flow_id
join public.customers c on c.id=f.customer_id
left join public.pick_return_orders pr on pr.job_id=j.id
where j.unit_id=(select id from public.business_units where code='TOOLTAG')
 and c.name like 'TEST-20261011-MANUAL-%'
order by c.name;
