-- Только чтение. Не меняет таблицы, права или данные.
select jsonb_pretty(jsonb_build_object(
 'columns',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select table_schema,table_name,column_name,data_type,is_nullable
 from information_schema.columns
 where (table_schema='public' and table_name='crm_profiles')
 or (table_schema='storage' and table_name in ('buckets','objects'))
 order by table_schema,table_name,ordinal_position) x),
 'functions',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as arguments,p.prosecdef,p.proconfig
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='public' and p.proname in ('crm_current_profile','crm_stock_read','crm_stock_command','crm_stock_photo_allowed'))
 or (n.nspname='auth' and p.proname='uid')) x),
 'policies',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select schemaname,tablename,policyname,roles,cmd,qual,with_check from pg_policies
 where schemaname='crm_stock' or (schemaname='storage' and tablename='objects')) x),
 'stock_schema_exists',exists(select 1 from information_schema.schemata where schema_name='crm_stock'),
 'stock_bucket',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select id,public,file_size_limit,allowed_mime_types from storage.buckets where id='crm-materials') x),
 'roles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select role,active,count(*) from public.crm_profiles group by role,active) x),
 'lead_roles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select name,role,active from public.crm_profiles where role in ('manager','director')) x)
)) as warehouse_check;
