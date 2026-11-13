-- DRAFT: review deployed crm_profiles/auth/storage schema before applying.
-- Does not alter orders, tasks, finance or their policies/functions.
begin;
-- Fail before making changes if the live prerequisites differ from the audit.
do $$
begin
 if exists(select 1 from pg_namespace where nspname='crm_stock') then
  raise exception 'Склад уже существует. Повторное применение запрещено';
 end if;
 if not coalesce((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='storage' and c.relname='objects'),false) then
  raise exception 'Для приватных фото требуется включённый RLS storage.objects. Остановлено без изменений';
 end if;
 if exists(select 1 from information_schema.columns where table_schema='storage' and table_name='buckets'
  and is_nullable='NO' and column_default is null and is_identity='NO' and is_generated='NEVER'
  and column_name not in ('id','name','public','file_size_limit','allowed_mime_types')) then
  raise exception 'Storage содержит дополнительные обязательные поля без значения по умолчанию. Нужна адаптация';
 end if;
end$$;
create schema if not exists crm_stock;
revoke all on schema crm_stock from public, anon, authenticated;
create table crm_stock.categories(id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 1 and 100));
create unique index stock_category_name on crm_stock.categories(lower(trim(name)));
insert into crm_stock.categories(name) values ('Ткани'),('Наполнители'),('Фурнитура'),('Упаковка'),('Прочее');
create table crm_stock.materials(
 id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 1 and 160),
 category_id uuid not null references crm_stock.categories, sku text not null default '',
 unit text not null check(unit in ('м','см','кг','г','шт.','упаковка')),
 description text not null default '' check(length(description)<=2000), photo text not null default '',
 active boolean not null default true, version int not null default 1);
create unique index stock_sku on crm_stock.materials(lower(regexp_replace(sku,'\s','','g'))) where trim(sku)<>'';
create unique index stock_material_name on crm_stock.materials(category_id,lower(trim(name)));
create table crm_stock.warehouses(id uuid primary key default gen_random_uuid(), owner_id uuid not null unique references public.crm_profiles(user_id), interval_days int not null default 14 check(interval_days between 1 and 365), version int not null default 1);
create table crm_stock.assignments(warehouse_id uuid references crm_stock.warehouses, material_id uuid references crm_stock.materials, active boolean not null default true, minimum numeric(14,3) check(minimum>=0), version int not null default 1, primary key(warehouse_id,material_id));
create table crm_stock.balances(warehouse_id uuid, material_id uuid, quantity numeric(14,3) not null check(quantity>=0), checked_at timestamptz not null, version int not null default 1, primary key(warehouse_id,material_id), foreign key(warehouse_id,material_id) references crm_stock.assignments);
create table crm_stock.sessions(id uuid primary key default gen_random_uuid(), warehouse_id uuid not null references crm_stock.warehouses, required_ids uuid[] not null, started_at timestamptz not null default now(), completed_at timestamptz, kind text not null default 'full' check(kind='full'));
create unique index stock_one_open_session on crm_stock.sessions(warehouse_id) where completed_at is null;
create table crm_stock.session_lines(session_id uuid references crm_stock.sessions, material_id uuid references crm_stock.materials, quantity numeric(14,3) not null, checked_at timestamptz not null default now(), primary key(session_id,material_id));
create table crm_stock.events(id bigint generated always as identity primary key, warehouse_id uuid references crm_stock.warehouses, material_id uuid references crm_stock.materials, session_id uuid references crm_stock.sessions, actor_id uuid not null, happened_at timestamptz not null default now(), action text not null, before_value jsonb, after_value jsonb, reason text);
create table crm_stock.requests(actor_id uuid not null, id uuid not null, payload jsonb not null, result jsonb not null, primary key(actor_id,id));
-- No direct browser access, including history writes. All checks are inside RPC.
do $$declare t record; begin for t in select tablename from pg_tables where schemaname='crm_stock' loop execute format('alter table crm_stock.%I enable row level security',t.tablename); end loop; end$$;
revoke all on all tables in schema crm_stock from public,anon,authenticated;

create function public.crm_stock_read(p_before bigint default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); admin boolean; result jsonb;
begin
 select role='manager' into admin from public.crm_profiles where user_id=uid and active;
 if admin is null then raise exception 'Требуется вход' using errcode='42501'; end if;
 select jsonb_build_object('admin',admin,
 'people',(select coalesce(jsonb_agg(jsonb_build_object('id',user_id,'name',name)), '[]') from public.crm_profiles where active and (admin or user_id=uid)),
 'categories',(select coalesce(jsonb_agg(to_jsonb(c) order by c.name),'[]') from crm_stock.categories c),
 'materials',(select coalesce(jsonb_agg(to_jsonb(m) order by m.name),'[]') from crm_stock.materials m where admin or exists(select 1 from crm_stock.assignments a join crm_stock.warehouses w on w.id=a.warehouse_id where a.material_id=m.id and w.owner_id=uid)),
 'warehouses',(select coalesce(jsonb_agg(to_jsonb(w)),'[]') from crm_stock.warehouses w where admin or w.owner_id=uid),
 'assignments',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from crm_stock.assignments a join crm_stock.warehouses w on w.id=a.warehouse_id where admin or w.owner_id=uid),
 'balances',(select coalesce(jsonb_agg(to_jsonb(b)),'[]') from crm_stock.balances b join crm_stock.warehouses w on w.id=b.warehouse_id where admin or w.owner_id=uid),
 'sessions',(select coalesce(jsonb_agg(to_jsonb(s)||jsonb_build_object('checked_count',(select count(*) from crm_stock.session_lines sl where sl.session_id=s.id))),'[]') from crm_stock.sessions s join crm_stock.warehouses w on w.id=s.warehouse_id where admin or w.owner_id=uid),
 'lines',(select coalesce(jsonb_agg(to_jsonb(l)),'[]') from crm_stock.session_lines l join crm_stock.sessions s on s.id=l.session_id join crm_stock.warehouses w on w.id=s.warehouse_id where s.completed_at is null and (admin or w.owner_id=uid)),
 'history',(select coalesce(jsonb_agg(to_jsonb(e) order by e.id desc),'[]') from (select e.* from crm_stock.events e left join crm_stock.warehouses w on w.id=e.warehouse_id where (admin or w.owner_id=uid) and (p_before is null or e.id<p_before) order by e.id desc limit 100) e)
 ) into result;
 return result;
end$$;

create function public.crm_stock_command(p_request uuid,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); admin boolean; op text:=p_payload->>'op'; cached crm_stock.requests;
 w crm_stock.warehouses; m crm_stock.materials; a crm_stock.assignments; b crm_stock.balances; s crm_stock.sessions;
 item jsonb; old jsonb; result jsonb; target uuid; mid uuid; qty numeric; minimum_value numeric; ids uuid[]; reason text;
begin
 select role='manager' into admin from public.crm_profiles where user_id=uid and active;
 if admin is null then raise exception 'Требуется вход' using errcode='42501'; end if;
 if p_request is null or p_payload is null or octet_length(p_payload::text)>100000 then raise exception 'Неверный запрос'; end if;
 -- Warehouse writes are short, infrequent transactions. Serialisation also protects
 -- catalog unit/archive changes against inventories and makes retries atomic.
 perform pg_advisory_xact_lock(773401,1);
 select * into cached from crm_stock.requests where actor_id=uid and id=p_request;
 if found then
  if cached.payload<>p_payload then raise exception 'Повтор запроса с другими данными'; end if;
  return cached.result;
 end if;
 if op in ('category','material','assign','settings','correct') and not admin then raise exception 'Нет доступа' using errcode='42501'; end if;
 if op='category' then
  insert into crm_stock.categories(name) values(trim(p_payload->>'name')) returning id into target;
 elsif op='material' then
  mid:=nullif(p_payload->>'id','')::uuid;
  if mid is not null then
   select * into m from crm_stock.materials where id=mid for update;
   if not found or m.version is distinct from (p_payload->>'version')::int then raise exception 'Материал изменился. Обновите данные'; end if;
   old:=to_jsonb(m);
   if m.unit is distinct from p_payload->>'unit' and (exists(select 1 from crm_stock.balances where material_id=mid) or exists(select 1 from crm_stock.assignments where material_id=mid and minimum is not null)) then raise exception 'Единица уже используется в остатках или нормах. Создайте отдельный материал'; end if;
  else mid:=gen_random_uuid(); end if;
  if coalesce(p_payload->>'photo','')<>'' and not exists(select 1 from storage.objects where bucket_id='crm-materials' and name=p_payload->>'photo') then raise exception 'Фото не загружено'; end if;
  insert into crm_stock.materials(id,name,category_id,sku,unit,description,photo,active)
  values(mid,trim(p_payload->>'name'),(p_payload->>'category_id')::uuid,trim(coalesce(p_payload->>'sku','')),p_payload->>'unit',coalesce(p_payload->>'description',''),coalesce(p_payload->>'photo',''),coalesce((p_payload->>'active')::boolean,true))
  on conflict(id) do update set name=excluded.name,category_id=excluded.category_id,sku=excluded.sku,unit=excluded.unit,description=excluded.description,photo=excluded.photo,active=excluded.active,version=crm_stock.materials.version+1;
  target:=mid;
  insert into crm_stock.events(actor_id,material_id,action,before_value,after_value) select uid,mid,'material',old,to_jsonb(x) from crm_stock.materials x where id=mid;
 elsif op='assign' then
  for item in select value from jsonb_array_elements(p_payload->'items') loop
   if not exists(select 1 from public.crm_profiles where user_id=(item->>'owner_id')::uuid and active) then raise exception 'Мастер недоступен'; end if;
   insert into crm_stock.warehouses(owner_id) values((item->>'owner_id')::uuid) on conflict(owner_id) do nothing;
   select * into w from crm_stock.warehouses where owner_id=(item->>'owner_id')::uuid;
   select * into m from crm_stock.materials where id=(item->>'material_id')::uuid;
   if not found then raise exception 'Материал не найден'; end if;
   select * into a from crm_stock.assignments where warehouse_id=w.id and material_id=m.id;
   if coalesce(a.version,0) is distinct from (item->>'version')::int then raise exception 'Назначения изменились. Обновите данные'; end if;
   minimum_value:=nullif(item->>'minimum','')::numeric;
   if minimum_value::text in ('NaN','Infinity','-Infinity') or minimum_value<0 or minimum_value<>round(minimum_value,3) or (m.unit in ('шт.','упаковка') and minimum_value<>trunc(minimum_value)) then raise exception 'Проверьте норму запаса'; end if;
   insert into crm_stock.assignments(warehouse_id,material_id,active,minimum) values(w.id,m.id,(item->>'active')::boolean,minimum_value)
   on conflict(warehouse_id,material_id) do update set active=excluded.active,minimum=excluded.minimum,version=crm_stock.assignments.version+1;
   insert into crm_stock.events(warehouse_id,material_id,actor_id,action,before_value,after_value) values(w.id,m.id,uid,'assignment',to_jsonb(a),item);
  end loop;
 else
  select * into w from crm_stock.warehouses where id=(p_payload->>'warehouse_id')::uuid for update;
  if not found or (not admin and w.owner_id<>uid) then raise exception 'Нет доступа к складу' using errcode='42501'; end if;
  target:=w.id;
  if op='settings' then
   if w.version is distinct from (p_payload->>'version')::int then raise exception 'Настройки изменились'; end if;
   update crm_stock.warehouses set interval_days=(p_payload->>'interval_days')::int,version=version+1 where id=w.id;
   insert into crm_stock.events(warehouse_id,actor_id,action,before_value,after_value) values(w.id,uid,op,to_jsonb(w),p_payload);
  elsif op='start' then
   select * into s from crm_stock.sessions where warehouse_id=w.id and completed_at is null;
   if not found then
    select array_agg(aa.material_id order by aa.material_id) into ids from crm_stock.assignments aa join crm_stock.materials mm on mm.id=aa.material_id where aa.warehouse_id=w.id and aa.active and mm.active;
    if coalesce(cardinality(ids),0)=0 then raise exception 'Нет назначенных материалов'; end if;
    insert into crm_stock.sessions(warehouse_id,required_ids) values(w.id,ids) returning * into s;
   end if;
   target:=s.id;
  elsif op in ('inventory','correct') then
   reason:=trim(coalesce(p_payload->>'reason',''));
   if op='correct' and length(reason) not between 3 and 1000 then raise exception 'Укажите причину исправления'; end if;
   if op='inventory' then
    select * into s from crm_stock.sessions where id=(p_payload->>'session_id')::uuid and warehouse_id=w.id and completed_at is null for update;
    if not found then raise exception 'Проверка уже завершена. Обновите данные'; end if;
   end if;
   if jsonb_typeof(p_payload->'items') is distinct from 'array' or jsonb_array_length(p_payload->'items')=0 then raise exception 'Отметьте проверенные позиции'; end if;
   for item in select value from jsonb_array_elements(p_payload->'items') loop
    mid:=(item->>'material_id')::uuid;
    select * into m from crm_stock.materials where id=mid;
    select * into a from crm_stock.assignments where warehouse_id=w.id and material_id=mid;
    if a.active is distinct from true or m.active is distinct from true then raise exception 'Материал больше не назначен'; end if;
    if op='inventory' and not(mid=any(s.required_ids)) then raise exception 'Материал не входит в эту проверку'; end if;
    if m.version is distinct from (item->>'material_version')::int or a.version is distinct from (item->>'assignment_version')::int then raise exception 'Материал или назначение изменились. Обновите данные'; end if;
    select * into b from crm_stock.balances where warehouse_id=w.id and material_id=mid for update;
    if coalesce(b.version,0) is distinct from (item->>'version')::int then raise exception 'Остаток изменился на другом устройстве. Обновите данные'; end if;
    qty:=(item->>'quantity')::numeric;
    if qty is null or qty<0 or qty>99999999999 or qty<>round(qty,3) or qty::text in ('NaN','Infinity','-Infinity') or (m.unit in ('шт.','упаковка') and qty<>trunc(qty)) then raise exception 'Проверьте количество'; end if;
    insert into crm_stock.balances(warehouse_id,material_id,quantity,checked_at) values(w.id,mid,qty,now())
    on conflict(warehouse_id,material_id) do update set quantity=excluded.quantity,checked_at=excluded.checked_at,version=crm_stock.balances.version+1;
    if op='inventory' then
     insert into crm_stock.session_lines(session_id,material_id,quantity) values(s.id,mid,qty)
     on conflict(session_id,material_id) do update set quantity=excluded.quantity,checked_at=excluded.checked_at;
    end if;
    insert into crm_stock.events(warehouse_id,material_id,session_id,actor_id,action,before_value,after_value,reason) values(w.id,mid,s.id,uid,op,to_jsonb(b),jsonb_build_object('quantity',qty,'unit',m.unit),nullif(reason,''));
   end loop;
   if op='inventory' then
    -- Ignore subsequently archived/unassigned positions, but never count newly assigned ones as checked.
    if not exists(select 1 from unnest(s.required_ids) r(id) join crm_stock.assignments aa on aa.material_id=r.id and aa.warehouse_id=w.id join crm_stock.materials mm on mm.id=r.id where aa.active and mm.active and not exists(select 1 from crm_stock.session_lines l where l.session_id=s.id and l.material_id=r.id)) then
     update crm_stock.sessions set completed_at=now() where id=s.id;
    end if;
   end if;
  else raise exception 'Неизвестная операция'; end if;
 end if;
 result:=jsonb_build_object('ok',true,'id',target);
 insert into crm_stock.requests(actor_id,id,payload,result) values(uid,p_request,p_payload,result);
 return result;
end$$;
revoke all on function public.crm_stock_read(bigint),public.crm_stock_command(uuid,jsonb) from public,anon;
grant execute on function public.crm_stock_read(bigint),public.crm_stock_command(uuid,jsonb) to authenticated;

-- Private photos: only managers upload; master can read assigned material photos.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('crm-materials','crm-materials',false,5242880,array['image/jpeg','image/png','image/webp']);
create function public.crm_stock_photo_allowed(p_name text,p_write boolean default false) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.crm_profiles p where p.user_id=auth.uid() and p.active and (p.role='manager' or (not p_write and exists(select 1 from crm_stock.warehouses w join crm_stock.assignments a on a.warehouse_id=w.id join crm_stock.materials m on m.id=a.material_id where w.owner_id=p.user_id and a.active and m.active and m.photo=p_name))))
$$;
revoke all on function public.crm_stock_photo_allowed(text,boolean) from public,anon;
grant execute on function public.crm_stock_photo_allowed(text,boolean) to authenticated;
create policy stock_photo_insert on storage.objects for insert to authenticated with check(bucket_id='crm-materials' and public.crm_stock_photo_allowed(name,true));
create policy stock_photo_read on storage.objects for select to authenticated using(bucket_id='crm-materials' and public.crm_stock_photo_allowed(name,false));
commit;
