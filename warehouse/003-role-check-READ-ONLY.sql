-- READ ONLY: models existing account identities under the authenticated DB role.
-- Does not log in as users, create materials, change balances or persist settings.
begin read only;
select set_config('request.jwt.claim.sub',(select user_id::text from public.crm_profiles where role='manager' and active order by name limit 1),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,true);
set local role authenticated;
select set_config('warehouse_check.manager',public.crm_stock_read()::text,true);
reset role;
select set_config('request.jwt.claim.sub',(select user_id::text from public.crm_profiles where role='director' and active order by name limit 1),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,true);
set local role authenticated;
select set_config('warehouse_check.director',public.crm_stock_read()::text,true);
reset role;
select set_config('request.jwt.claim.sub',(select user_id::text from public.crm_profiles where role='master' and active order by name limit 1),true);
select set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('request.jwt.claim.sub'),'role','authenticated')::text,true);
set local role authenticated;
select set_config('warehouse_check.master',public.crm_stock_read()::text,true);
reset role;
select jsonb_pretty(jsonb_build_object(
 'alexandra',jsonb_build_object('admin',a->'admin','visible_people',jsonb_array_length(a->'people'),'categories',jsonb_array_length(a->'categories')),
 'dasha',jsonb_build_object('admin',d->'admin','visible_people',jsonb_array_length(d->'people'),'only_self',jsonb_array_length(d->'people')=1,'categories',jsonb_array_length(d->'categories')),
 'master',jsonb_build_object('admin',m->'admin','visible_people',jsonb_array_length(m->'people'),'only_self',jsonb_array_length(m->'people')=1,'categories',jsonb_array_length(m->'categories')),
 'passed',(a->>'admin')::boolean and not (d->>'admin')::boolean and not (m->>'admin')::boolean and jsonb_array_length(d->'people')=1 and jsonb_array_length(m->'people')=1
)) as warehouse_role_check
from (select current_setting('warehouse_check.manager')::jsonb a,current_setting('warehouse_check.director')::jsonb d,current_setting('warehouse_check.master')::jsonb m) q;
rollback;
