-- Только чтение. Проверка установки склада без создания тестовых данных.
select jsonb_pretty(jsonb_build_object(
 'tables',(select jsonb_agg(jsonb_build_object('name',c.relname,'rls',c.relrowsecurity,
 'anon_select',has_table_privilege('anon',c.oid,'SELECT'),
 'authenticated_select',has_table_privilege('authenticated',c.oid,'SELECT'),
 'authenticated_insert',has_table_privilege('authenticated',c.oid,'INSERT'),
 'authenticated_update',has_table_privilege('authenticated',c.oid,'UPDATE'),
 'authenticated_delete',has_table_privilege('authenticated',c.oid,'DELETE')) order by c.relname)
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='crm_stock' and c.relkind='r'),
 'schema_access',jsonb_build_object('anon',has_schema_privilege('anon','crm_stock','USAGE'),'authenticated',has_schema_privilege('authenticated','crm_stock','USAGE')),
 'functions',(select jsonb_agg(jsonb_build_object('name',p.proname,'security_definer',p.prosecdef,'settings',p.proconfig,
 'anon_execute',has_function_privilege('anon',p.oid,'EXECUTE'),
 'authenticated_execute',has_function_privilege('authenticated',p.oid,'EXECUTE')) order by p.proname)
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('crm_stock_read','crm_stock_command','crm_stock_photo_allowed')),
 'photo_bucket',(select to_jsonb(b) from (select id,public,file_size_limit,allowed_mime_types from storage.buckets where id='crm-materials') b),
 'storage_rls',(select relrowsecurity from pg_class where oid='storage.objects'::regclass),
 'storage_policies',(select jsonb_agg(to_jsonb(p)) from (select policyname,roles,cmd,qual,with_check from pg_policies where schemaname='storage' and tablename='objects') p),
 'counts',jsonb_build_object('categories',(select count(*) from crm_stock.categories),'materials',(select count(*) from crm_stock.materials),'warehouses',(select count(*) from crm_stock.warehouses),'balances',(select count(*) from crm_stock.balances),'sessions',(select count(*) from crm_stock.sessions),'events',(select count(*) from crm_stock.events),'requests',(select count(*) from crm_stock.requests))
)) as warehouse_verification;
