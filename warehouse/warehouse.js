/* Isolated warehouse module: never writes orders, finance, tasks or their dirty queue. */
(function(global){
'use strict';
const units=['м','см','кг','г','шт.','упаковка'];
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const number=s=>{if(String(s).trim()==='')throw Error('Введите количество');const n=Number(String(s).replace(',','.'));if(!Number.isFinite(n)||n<0||Math.abs(n*1000-Math.round(n*1000))>0.00001)throw Error('Количество должно быть неотрицательным, до 3 знаков после запятой');return n;};
const status=(balance,assignment,days,now=Date.now())=>!balance?'unknown':now-Date.parse(balance.checked_at)>days*86400000?'stale':assignment.minimum!=null&&Number(balance.quantity)<Number(assignment.minimum)?'low':'ok';
const fmt=n=>n==null?'Не проверено':Number(n).toLocaleString('ru-RU');
const date=s=>s?new Date(s).toLocaleString('ru-RU',{day:'numeric',month:'short',year:'numeric'}):'Ещё не было';
let data=null,view='overview',selected='',error='',loading=false,busy=false,pending=null,draft={},search='',category='',includeArchive=false,older=[],ownerKey='';
let previewMaster=false,saveNotice=null;
const collapsedGroups=new Set();
const host=()=>document.querySelector('#warehouse-root');
const el=id=>document.getElementById('wh-'+id);
const button=(text,action,attrs='')=>`<button type="button" class="btn" data-action="${action}" ${attrs}>${text}</button>`;
const option=(id,name,current)=>`<option value="${escape(id)}" ${id===current?'selected':''}>${escape(name)}</option>`;
async function rpc(name,payload){const r=await sbFetch(SB_URL+'/rest/v1/rpc/'+name,{method:'POST',headers:{...sbHeaders(),'Content-Type':'application/json'},body:JSON.stringify(payload)});const d=await r.json();if(!r.ok){const e=Error(d.message||'Не удалось сохранить');e.confirmed=r.status>=400&&r.status<500&&![408,429].includes(r.status);throw e;}return d;}
function pendingStore(action,value,key=ownerKey){return new Promise((resolve,reject)=>{const req=indexedDB.open('markovtoys-warehouse',1);req.onupgradeneeded=()=>req.result.createObjectStore('pending');req.onerror=()=>reject(Error('Не удалось открыть хранилище запроса. Сохранение не отправлено'));req.onsuccess=()=>{const db=req.result,tx=db.transaction('pending',action==='get'?'readonly':'readwrite'),store=tx.objectStore('pending');const r=action==='get'?store.get(key):action==='put'?store.put(value,key):store.delete(key);let result;r.onsuccess=()=>result=r.result;tx.oncomplete=()=>{db.close();resolve(result)};tx.onerror=()=>{db.close();reject(Error('Не удалось сохранить подтверждение запроса на устройстве'))};};});}
function own(w){return data.people.find(p=>p.id===w.owner_id)?.name||'Мастер';}
function warehouse(){return data.warehouses.find(w=>w.id===selected)||data.warehouses[0];}
function rows(w){return data.assignments.filter(a=>a.warehouse_id===w?.id&&a.active).map(a=>({a,m:data.materials.find(m=>m.id===a.material_id),b:data.balances.find(b=>b.warehouse_id===w.id&&b.material_id===a.material_id)})).filter(r=>r.m?.active);}
function session(w){return data.sessions.find(s=>s.warehouse_id===w?.id&&!s.completed_at);}
function last(w){return data.sessions.filter(s=>s.warehouse_id===w.id&&s.completed_at).sort((a,b)=>b.completed_at.localeCompare(a.completed_at))[0];}
function due(w){const l=last(w);return l?Date.parse(l.completed_at)+w.interval_days*86400000:null;}
function summary(w){const rs=rows(w),valid=rs.filter(r=>status(r.b,r.a,w.interval_days)!=='unknown'&&status(r.b,r.a,w.interval_days)!=='stale').length;return `${valid} из ${rs.length} актуальны · полная проверка: ${date(last(w)?.completed_at)}`;}
async function load(reconcile=false){
 if(loading)return;
 const key=ownerKey;loading=true;error='';paint();
 try{
  const next=await rpc('crm_stock_read',{});if(key!==ownerKey)return;
  data=next;
  if(!data.warehouses.some(w=>w.id===selected))selected=data.warehouses[0]?.id||'';
  if(reconcile){
   const stock=rows(warehouse());
   for(const [id,entry] of Object.entries(draft)){
    const item=stock.find(r=>r.m.id===id);
    if(!item){delete draft[id];continue;}
    const fresh=line(item,0),old=entry.baseline;
    if(old&&['version','assignment_version','material_version'].some(k=>fresh[k]!==old[k])){
     draft[id]={...entry,baseline:null,checked:false};
    }
   }
   saveNotice=null;
  }
 }catch(e){if(key===ownerKey)error='Склад пока недоступен. '+e.message;}
 finally{if(key===ownerKey){loading=false;paint();}}
}
async function mount(){const key=crmProfile?.id||crmProfile?.user_id||'';if(key!==ownerKey){data=null;pending=null;draft={};saveNotice=null;collapsedGroups.clear();previewMaster=false;busy=false;loading=false;older=[];ownerKey=key;}const h=host();if(!h)return;h.onclick=click;h.oninput=input;h.onchange=change;h.addEventListener('toggle',rememberGroup,true);paint();try{const restored=await pendingStore('get');if(key!==ownerKey)return;if(!busy){pending=restored||null;recoverInventoryDraft(pending);if(pending&&(pending.queuedItems||pending.payload.op==='inventory')){selected=pending.payload.warehouse_id;view='masters';}}}catch(e){if(key!==ownerKey)return;error=e.message;}paint();load();}
function rememberGroup(e){
 const group=e.target;
 if(!group.dataset?.whGroup||!group.isConnected||group.dataset.filtered)return;
 if(group.open)collapsedGroups.delete(group.dataset.whGroup);
 else collapsedGroups.add(group.dataset.whGroup);
}
function groupStart(category,count,scope,filtered=false){
 const key=scope+':'+category.id;
 return `<details class="wh-group" data-wh-group="${escape(key)}" ${filtered?'data-filtered="true"':''} ${filtered||!collapsedGroups.has(key)?'open':''}><summary><b>${escape(category.name)}</b><span>${count}</span></summary>`;
}
function saveFeedback(){
 const notice=pending?{type:'error',title:'Сохранение не подтверждено',text:'Данные остались на этом устройстве. Повтор отправит тот же запрос без дублей.',action:'retry',label:'Повторить сохранение'}:saveNotice;
 if(busy&&(pending||saveNotice))return '<div class="wh-save-feedback"><div class="wh-save-card" role="status"><strong>Сохраняем остатки…</strong></div></div>';
 if(!notice)return '';
 return `<div class="wh-save-feedback"><div class="wh-save-card wh-save-${notice.type}" role="${notice.type==='error'?'alert':'status'}"><strong>${escape(notice.title)}</strong>${notice.text?`<p>${escape(notice.text)}</p>`:''}<div class="wh-save-actions">${notice.action?button(notice.label,notice.action):''}${pending?'':button('Закрыть','dismiss-save')}</div></div></div>`;
}
function paint(){const h=host();if(!h)return;if(isPreviewMode){h.innerHTML='<div class="card wh-box">Склад открывается только в собственном аккаунте. Режим просмотра не используется для проверки прав.</div>';return;}
 h.innerHTML=`<div class="wh-message ${error==='Сохранено на сервере'?'wh-success':''}" role="status">${loading?'Загрузка склада…':busy?'Сохраняем…':escape(error)}</div>`+saveFeedback();
 if(!data){h.innerHTML+=button('Повторить загрузку','reload');return;}
 if(data.admin&&previewMaster){
   h.innerHTML+=`<div class="wh-preview"><b>Вид мастера · только просмотр</b>${button('Вернуться','close-preview')}</div>`+master(true);
   hydratePhotos();
   return;
 }
 h.innerHTML+=`<div class="wh-navigation">${data.admin?`<nav class="wh-tabs" aria-label="Разделы склада">${[['overview','Обзор'],['materials','Материалы'],['masters','По мастерам'],['history','История']].map(([id,t])=>button(t,'view',`data-view="${id}" aria-pressed="${view===id}"`)).join('')}</nav>`:''}<button type="button" class="wh-reload" data-action="reload" aria-label="Обновить данные" title="Обновить данные">↻</button></div>`;
 h.innerHTML+=data.admin?(view==='materials'?catalog():view==='history'?history():view==='masters'?master():overview()):master();
 h.querySelectorAll('button,input,select,textarea').forEach(n=>{if(busy||pending||loading)n.disabled=n.dataset.action!=='retry'||busy||loading;});
 hydratePhotos();
}
function coverage(list){
 const counts=[0,0,0,0],states=['ok','low','stale','unknown'];
 for(const {a,b,w} of list)counts[states.indexOf(status(b,a,w.interval_days))]++;
 const labels=['Проверены','Ниже минимума','Пора проверить','Нет данных'];
 return list.length?`<div class="wh-coverage"><div class="wh-meter" aria-hidden="true">${counts.map((n,i)=>n?`<span class="wh-tone-${i}" style="flex:${n}"></span>`:'').join('')}</div><div class="wh-legend">${labels.map((label,i)=>`<span><i class="wh-tone-${i}"></i>${label} <b>${counts[i]}</b></span>`).join('')}</div></div>`:'<p class="muted">Назначьте материалы мастерам, чтобы увидеть сводку остатков.</p>';
}
function overview(){
 const all=data.warehouses.flatMap(w=>rows(w).map(r=>({...r,w})));
 return `<section class="wh-panel"><h2>Состояние запасов</h2>${coverage(all)}</section><h2 class="wh-section-title">Склады мастеров</h2><div class="wh-list">${data.people.map(p=>{
   const w=data.warehouses.find(w=>w.owner_id===p.id);
   return `<article class="wh-person-row"><div><b>${escape(p.name)}</b><p>${w?escape(summary(w)):'Материалы ещё не назначены'}</p></div>${w?button('Открыть остатки','select',`data-id="${w.id}"`):button('Назначить материалы','assign',`data-person="${p.id}"`)}</article>`;
 }).join('')}</div>`;
}
function catalog(){
 return `<div class="wh-catalog-tools">
  <div class="wh-catalog-actions"><button type="button" class="btn btn-primary" data-action="material">+ Добавить материал</button>
  <details class="wh-tools"><summary>Ещё действия</summary><div>${button('+ Категория','category')}${button('Назначить материалы','assign')}<label class="wh-check"><input id="wh-archive" type="checkbox" ${includeArchive?'checked':''}> Показать архив материалов</label></div></details></div>
  <div class="wh-catalog-filters"><input id="wh-search" type="search" aria-label="Поиск материала" placeholder="Название или артикул" value="${escape(search)}"><select aria-label="Категория материалов" id="wh-category">${option('','Все категории',category)}${orderedCategories().map(c=>option(c.id,c.name,category)).join('')}</select></div>
 </div><div id="wh-catalog-list">${catalogRows()}</div>`;
}
function orderedCategories(){
 const preferred=['Ткани одежда','Ткани','Букле','Наполнители','Фурнитура','Упаковка','Прочее'];
 const rank=name=>{const n=preferred.indexOf(name);return n<0?preferred.length:n;};
 return [...data.categories].sort((a,b)=>rank(a.name)-rank(b.name)||a.name.localeCompare(b.name,'ru'));
}
function paletteNumber(material){
 for(const label of [material.sku,material.name]){
  const match=String(label||'').trim().match(/^(?:[НH№]\s*)(1[0-6]|[1-9])(?=$|[\s.·–—-])/iu);
  if(match)return Number(match[1]);
 }
 return Infinity;
}
function compareMaterials(a,b){
 const x=paletteNumber(a),y=paletteNumber(b);
 if(x!==y)return x<y?-1:1;
 return a.name.localeCompare(b.name,'ru',{numeric:true});
}
function purchaseLinks(description){
 const matches=String(description||'').match(/https?:\/\/[^\s<>"']+/gi)||[];
 return [...new Set(matches.map(match=>match.replace(/[.,;!?\])]+$/g,'')).filter(isPurchaseUrl))];
}
function isPurchaseUrl(value){
 try{const url=new URL(value);return /^https?:$/.test(url.protocol)&&!!url.hostname&&!url.username&&!url.password;}
 catch{return false;}
}
function procurement(m){
 const links=purchaseLinks(m.description);
 return links.length?`<div class="wh-purchase">${links.map((href,i)=>{
  const host=new URL(href).hostname.replace(/^www\./,'');
  const name=host==='wildberries.ru'?'WB':host==='ozon.ru'?'Ozon':host;
  const duplicateStore=links.filter(l=>new URL(l).hostname.replace(/^www\./,'')===host).length>1;
  const above=String(m.description).split(href,1)[0].trimEnd().split('\n').at(-1)||'';
  const vendor=duplicateStore&&above.match(/^(Arben|Айхал)\b|^(Айхал)(?=\s|$)/iu)?.[0];
  const caption=vendor||name+(duplicateStore?' '+(i+1):'');
  return `<a class="wh-buy" href="${escape(href)}" target="_blank" rel="noopener noreferrer" aria-label="Закупить: ${escape(m.name)} · ${escape(caption)}">${links.length===1?'Закупить · ':''}${escape(caption)} ↗</a>`;
 }).join('')}</div>`:'';
}
function catalogRows(){
 const query=search.trim().toLowerCase().replace(/^[hн№]\s*(?=\d)/u,'н');
 const list=data.materials.filter(m=>(m.active||includeArchive)&&(!category||m.category_id===category)&&`${m.name} ${m.sku}`.toLowerCase().includes(query));
 if(!list.length)return '<p class="wh-empty">По этому запросу материалов нет.</p>';
 return orderedCategories().map(c=>{
  const materials=list.filter(m=>m.category_id===c.id).sort(compareMaterials);
  return materials.length?`${groupStart(c,materials.length,'catalog',!!query||!!category)}<div class="wh-list">${materials.map(m=>`<article class="wh-material">
   ${photo(m)||'<span class="wh-photo wh-photo-empty" aria-hidden="true"></span>'}
   <div class="wh-material-main"><button type="button" class="wh-material-name" data-action="material" data-id="${m.id}">${escape(m.name)}</button><p>${[m.sku,m.unit,m.active?'':'Архив'].filter(Boolean).map(escape).join(' · ')}</p></div>
   <div class="wh-material-actions">${procurement(m)}${button('Остатки','material-balances',`data-id="${m.id}"`)}</div></article>`).join('')}</div></details>`:'';
 }).join('');
}
function photo(m){return m.photo?`<img class="wh-photo" data-photo="${escape(m.photo)}" alt="${escape(m.name)}" loading="lazy" decoding="async">`:'';}
async function hydratePhotos(){for(const img of host()?.querySelectorAll('[data-photo]')||[]){try{const r=await sbFetch(SB_URL+'/storage/v1/object/sign/crm-materials/'+img.dataset.photo,{method:'POST',headers:{...sbHeaders(),'Content-Type':'application/json'},body:JSON.stringify({expiresIn:300})});const d=await r.json();if(r.ok&&d.signedURL)img.src=SB_URL+'/storage/v1'+d.signedURL;}catch{img.alt='Фото временно недоступно';}}}
function master(asMaster=false){
 const w=warehouse(),admin=data.admin&&!asMaster;
 let h=admin?`<div class="wh-toolbar wh-master-tools"><select aria-label="Склад мастера" id="wh-person">${data.warehouses.map(x=>option(x.id,own(x),w?.id)).join('')}</select>${w?button('Как видит мастер','preview-master'):''}<details class="wh-tools"><summary>Настройки</summary><div>${button('Назначения и нормы','assign',`data-person="${w?.owner_id||''}"`)}${w?button('Периодичность','settings'):''}</div></details></div>`:'<h2 class="wh-section-title">Мой склад</h2>';
 const stock=rows(w);
 if(!stock.length)return h+'<p class="wh-empty">Материалы появятся здесь после назначения.</p>';
 const ss=session(w),checked=new Set(data.lines.filter(l=>l.session_id===ss?.id).map(l=>l.material_id)),next=due(w);
 const primary=(text,action)=>`<button type="button" class="btn btn-primary" data-action="${action}" ${asMaster?'disabled':''}>${text}</button>`;
 h+=`<section class="wh-panel wh-master-summary"><div><b>${escape(own(w))}</b><p>${escape(summary(w))}</p><p class="${next&&next<Date.now()?'wh-overdue':''}">${next?'Следующая проверка: '+date(next):'Нужна первая проверка'}</p>${ss?`<p>Проверено ${checked.size} из ${ss.required_ids.length}</p>`:''}</div>${primary('Сохранить проверенные','save')}</section>`;
 for(const c of orderedCategories()){
  const group=stock.filter(r=>r.m.category_id===c.id).sort((x,y)=>compareMaterials(x.m,y.m));
  if(!group.length)continue;
  h+=groupStart(c,group.length,w.id)+'<div class="wh-list">';
  for(const {a,m,b} of group){
   const st=status(b,a,w.interval_days),d=asMaster?null:draft[m.id],included=!ss||ss.required_ids.includes(m.id);
   const badge={low:'Нужно пополнить',stale:'Пора проверить',unknown:'Нет данных'}[st];
   h+=`<article class="wh-stock ${st==='low'?'wh-low':''}">${photo(m)||'<span class="wh-photo wh-photo-empty" aria-hidden="true"></span>'}
   <div class="wh-stock-body"><div class="wh-stock-title"><b>${escape(m.name)}</b><strong>${b?fmt(b.quantity)+' '+escape(m.unit):'—'}</strong></div>
   <div class="wh-stock-meta">${badge?`<span class="wh-stock-status wh-status-${st}">${badge}</span>`:''}${b?`<span>Проверено ${date(b.checked_at)}</span>`:''}${a.minimum!=null?`<span>Минимум ${fmt(a.minimum)} ${escape(m.unit)}</span>`:''}</div>
   ${d&&d.baseline===null?'<p class="wh-stock-status wh-status-stale">Сверьте введённое число с новым остатком</p>':''}
   ${included?`<div class="wh-count-input"><label>Факт, ${escape(m.unit)} <input aria-label="Фактический остаток: ${escape(m.name)}" data-quantity="${m.id}" inputmode="decimal" value="${escape(d?.quantity??b?.quantity??'')}" placeholder="—" ${asMaster?'disabled':''}></label><label class="wh-check"><input type="checkbox" data-checked="${m.id}" ${d?.checked?'checked':''} ${asMaster?'disabled':''}> Проверено${checked.has(m.id)?' (ранее сохранено)':''}</label></div>`:'<p class="wh-stock-meta">Новая позиция · в следующей проверке</p>'}
   ${admin?button('Исправить','correct',`data-id="${m.id}"`):''}</div></article>`;
  }
  h+='</div></details>';
 }
 h+=`<div class="wh-toolbar">${primary('Сохранить проверенные','save')}<span>Можно сохранить частями.</span></div>`;
 return h;
}
function history(){const events=[...data.history,...older];return `<div class="wh-session-list">${data.sessions.map(s=>{const w=data.warehouses.find(w=>w.id===s.warehouse_id);return `<details class="card wh-box"><summary>${escape(w?own(w):'Мастер')} · ${s.completed_at?'Завершена':'Частичная проверка'}</summary><p>Начало: ${date(s.started_at)} · проверено ${s.checked_count??0} из ${s.required_ids.length}</p>${s.completed_at?`<p>Завершена: ${date(s.completed_at)}</p>`:''}</details>`;}).join('')}</div><p class="muted">История проверок, исправлений и настроек. По 100 записей на страницу.</p>${events.map(e=>{const m=data.materials.find(m=>m.id===e.material_id),w=data.warehouses.find(w=>w.id===e.warehouse_id);return `<article class="card wh-box"><b>${escape(w?own(w):'Каталог')} · ${escape(m?.name||'Настройки')}</b><p>${date(e.happened_at)} · ${escape({inventory:'Инвентаризация',correct:'Исправление',material:'Материал',assignment:'Назначение',settings:'Периодичность'}[e.action]||e.action)}</p>${['inventory','correct'].includes(e.action)?`<p>${fmt(e.before_value?.quantity)} → ${fmt(e.after_value?.quantity)} ${escape(e.after_value?.unit||'')}</p>`:''}${e.reason?`<p>Причина: ${escape(e.reason)}</p>`:''}</article>`;}).join('')}${events.length&&events.length%100===0?button('Ещё записи','history-more'):''}`;}
function dialog(title,body,onSubmit){const dlg=document.createElement('dialog');dlg.className='wh-dialog';dlg.innerHTML=`<form><h2>${escape(title)}</h2>${body}<p class="wh-form-error" role="alert"></p><div class="wh-toolbar"><button type="button" class="btn" data-close>Отмена</button><button class="btn btn-primary" type="submit">Сохранить</button></div></form>`;document.body.append(dlg);dlg.querySelector('[data-close]').onclick=()=>dlg.close();dlg.onclose=()=>dlg.remove();dlg.querySelector('form').onsubmit=async e=>{e.preventDefault();const btn=dlg.querySelector('[type=submit]');btn.disabled=true;try{await onSubmit(new FormData(e.target),dlg);dlg.close();}catch(err){dlg.querySelector('.wh-form-error').textContent=err.message;}finally{btn.disabled=false;}};dlg.showModal();return dlg;}
const materialPhotoFormats={'image/jpeg':'jpg','image/png':'png','image/webp':'webp'};
const materialPhotoTarget=250*1024;
async function compressMaterialPhoto(file){
  if(!Object.hasOwn(materialPhotoFormats,file.type)||file.size>25*1024*1024){
    throw Error('Выберите фото в формате JPEG, PNG или WebP до 25 МБ');
  }
  const image=new Image();
  const source=URL.createObjectURL(file);
  const canvas=document.createElement('canvas');
  try{
    image.src=source;
    try{await image.decode();}catch{throw Error('Не удалось открыть фото. Выберите другой файл');}
    const longest=Math.max(image.naturalWidth,image.naturalHeight);
    if(longest<=1000&&file.size<=materialPhotoTarget)return file;

    const ctx=canvas.getContext('2d',{alpha:false});
    if(!ctx)throw Error('Не удалось подготовить фото в этом браузере');
    for(const edge of [1000,800,640,480,360]){
      const scale=Math.min(1,edge/longest);
      canvas.width=Math.max(1,Math.round(image.naturalWidth*scale));
      canvas.height=Math.max(1,Math.round(image.naturalHeight*scale));
      ctx.fillStyle='#fff';
      ctx.fillRect(0,0,canvas.width,canvas.height);
      ctx.imageSmoothingQuality='high';
      ctx.drawImage(image,0,0,canvas.width,canvas.height);
      for(const quality of [0.85,0.72,0.6]){
        const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',quality));
        if(!blob||blob.type!=='image/jpeg')throw Error('Не удалось сжать фото в этом браузере');
        if(blob.size<=materialPhotoTarget)return blob;
      }
    }
    throw Error('Не удалось уменьшить фото до 250 КБ. Выберите другой файл');
  }finally{
    URL.revokeObjectURL(source);
    canvas.width=canvas.height=0;
  }
}
function materialForm(id){const m=data.materials.find(m=>m.id===id)||{active:true,unit:'м'};dialog(id?'Изменить материал':'Новый материал',`<div class="wh-material-form"><label class="wh-wide">Название<input name="name" required maxlength="160" value="${escape(m.name||'')}"></label><label>Категория<select name="category_id">${data.categories.map(c=>option(c.id,c.name,m.category_id)).join('')}</select></label><label>Артикул<input name="sku" value="${escape(m.sku||'')}"></label><label>Единица<select name="unit">${units.map(u=>option(u,u,m.unit)).join('')}</select></label><label class="wh-wide">Описание и ссылки закупки<textarea placeholder="Вставьте ссылки на магазины, по одной на строку" name="description" maxlength="2000">${escape(m.description||'')}</textarea></label><label class="wh-wide">Фото (JPEG, PNG, WebP до 25 МБ)<input type="file" name="photo_file" accept="image/jpeg,image/png,image/webp"><small class="muted">CRM автоматически уменьшит фото перед загрузкой.</small></label><label class="wh-check wh-wide"><input name="active" type="checkbox" ${m.active?'checked':''}> Используется</label></div>`,async f=>{let photo=m.photo||'';const file=f.get('photo_file');if(file?.size){const image=await compressMaterialPhoto(file);photo=crypto.randomUUID()+'.'+materialPhotoFormats[image.type];const r=await sbFetch(SB_URL+'/storage/v1/object/crm-materials/'+photo,{method:'POST',headers:{...sbHeaders(),'Content-Type':image.type},body:image});if(!r.ok)throw Error('Фото не загрузилось');}await command({op:'material',id:m.id||null,version:m.version,name:f.get('name'),category_id:f.get('category_id'),sku:f.get('sku'),unit:f.get('unit'),description:f.get('description'),active:f.has('active'),photo});});}
function assignForm(person){const people=person?data.people.filter(p=>p.id===person):data.people;dialog('Назначения и минимальные запасы',`<p>Пустой минимум — норма не задана. Назначение не устанавливает остаток.</p>${people.map(p=>{const w=data.warehouses.find(w=>w.owner_id===p.id);return `<details ${person?'open':''}><summary>${escape(p.name)}</summary><button type="button" class="btn" onclick="this.parentElement.querySelectorAll('input[type=checkbox]').forEach(n=>n.checked=true)">Выбрать все</button>${data.materials.filter(m=>m.active).map(m=>{const a=data.assignments.find(a=>a.warehouse_id===w?.id&&a.material_id===m.id);return `<div class="wh-assign"><label class="wh-check"><input type="checkbox" name="a:${p.id}:${m.id}" ${a?.active?'checked':''}>${escape(m.name)} · ${escape(m.unit)}</label><input aria-label="Минимум ${escape(m.name)}" inputmode="decimal" placeholder="Минимум не задан" name="n:${p.id}:${m.id}" value="${escape(a?.minimum??'')}"></div>`;}).join('')}</details>`;}).join('')}`,async f=>{const items=[];for(const p of people){const w=data.warehouses.find(w=>w.owner_id===p.id);for(const m of data.materials.filter(m=>m.active)){const a=data.assignments.find(a=>a.warehouse_id===w?.id&&a.material_id===m.id),active=f.has(`a:${p.id}:${m.id}`),raw=f.get(`n:${p.id}:${m.id}`),minimum=String(raw).trim()===''?null:number(raw);if((a?.active||false)!==active||(a?.minimum??null)!==minimum)items.push({owner_id:p.id,material_id:m.id,version:a?.version||0,active,minimum});}}if(!items.length)return;await command({op:'assign',items});});}
function input(e){if(e.target.id==='wh-search'){search=e.target.value;el('catalog-list').innerHTML=catalogRows();hydratePhotos();}if(e.target.dataset.quantity){const id=e.target.dataset.quantity;draft[id]={...draft[id],baseline:draft[id]?.baseline||line(rows(warehouse()).find(r=>r.m.id===id),0),quantity:e.target.value,checked:true};const check=host().querySelector(`[data-checked="${id}"]`);if(check)check.checked=true;}}
function change(e){if(e.target.id==='wh-archive'){includeArchive=e.target.checked;paint();}if(e.target.id==='wh-category'){category=e.target.value;paint();}if(e.target.id==='wh-person'){if(Object.values(draft).some(d=>d.checked)&&!confirm('Перейти к другому складу без сохранения введённых значений?')){e.target.value=selected;return;}selected=e.target.value;draft={};paint();}if(e.target.dataset.checked){const id=e.target.dataset.checked;draft[id]={...draft[id],baseline:draft[id]?.baseline||line(rows(warehouse()).find(r=>r.m.id===id),0),quantity:host().querySelector(`[data-quantity="${id}"]`).value,checked:e.target.checked};}}
function line(r,q){return {material_id:r.m.id,quantity:number(q),version:r.b?.version||0,assignment_version:r.a.version,material_version:r.m.version};}
async function sendWarehouseRequest(request){
 const reply=await rpc('crm_stock_command',{p_request:request.id,p_payload:request.payload});
 if(reply?.ok!==true)throw Error('Сервер не подтвердил сохранение');
 return reply;
}
function recoverInventoryDraft(request){
 const items=request?.queuedItems||(request?.payload.op==='inventory'?request.payload.items:null);
 if(!items)return;
 for(const item of items){
  const {material_id,quantity,...versions}=item;
  if(!draft[material_id])draft[material_id]={quantity:String(quantity),checked:true,baseline:{material_id,...versions}};
 }
}
async function command(payload,retry=false,queuedItems=null){
 if(busy||loading)throw Error('Дождитесь сохранения и обновления склада');
 if(isPreviewMode||previewMaster)throw Error('В режиме просмотра сохранение недоступно');
 if(pending&&!retry)throw Error('Сначала повторите неподтверждённый запрос');
 if(retry&&!pending)return;
 const key=ownerKey;
 const inventory=payload?.op==='inventory'||queuedItems||pending?.payload.op==='inventory'||pending?.queuedItems;
 if(inventory)saveNotice={type:'success',title:'Сохраняем остатки…'};
 busy=true;error='';paint();
 try{
  if(!retry){
   const request={id:crypto.randomUUID(),payload,...(queuedItems?{queuedItems}:{})};
   await pendingStore('put',request,key);
   if(key!==ownerKey)return;
   pending=request;
  }
  let request=pending;
  const reply=await sendWarehouseRequest(request);
  if(key!==ownerKey)return;
  if(request.queuedItems){
   if(typeof reply.id!=='string'||!reply.id)throw Error('Сервер не подтвердил начало проверки');
   const next={id:crypto.randomUUID(),payload:{op:'inventory',warehouse_id:request.payload.warehouse_id,session_id:reply.id,items:request.queuedItems}};
   // Persist the next request before sending it. A retry can only replay one saved step.
   await pendingStore('put',next,key);
   if(key!==ownerKey)return;
   pending=next;
   request=next;
   await sendWarehouseRequest(request);
   if(key!==ownerKey)return;
  }
  await pendingStore('delete',null,key);
  if(key!==ownerKey)return;
  pending=null;draft={};error='Сохранено на сервере';
  if(inventory)saveNotice={type:'success',title:'Успешно сохранено',text:'Сервер подтвердил запись остатков.'};
  try{const next=await rpc('crm_stock_read',{});if(key!==ownerKey)return;data=next;}
  catch(e){
   if(key!==ownerKey)return;
   error='Сохранено на сервере, но не удалось обновить экран. Нажмите «Обновить данные».';
   if(inventory)saveNotice.text='Сервер подтвердил запись остатков. Обновите данные, чтобы увидеть новые значения.';
  }
 }catch(e){
  if(key!==ownerKey)return;
  if(e.confirmed&&pending){
   recoverInventoryDraft(pending);
   await pendingStore('delete',null,key);
   if(key!==ownerKey)return;
   pending=null;
  }
  error=e.message;
  if(inventory&&!pending)saveNotice={type:'error',title:'Остатки не сохранены',text:e.message,action:e.confirmed?'reconcile-stock':'save',label:e.confirmed?'Сверить остатки':'Повторить сохранение'};
  throw e;
 }finally{if(key===ownerKey){busy=false;paint();}}
}
async function click(e){const btn=e.target.closest('[data-action]');if(!btn||busy)return;const a=btn.dataset.action,w=data&&warehouse();try{
 if(previewMaster){if(a==='close-preview'){previewMaster=false;paint();}return;}
 if(a==='preview-master'&&data.admin&&w){previewMaster=true;paint();return;}
 if(a==='retry')await command(null,true);
 if(a==='reload'){if(Object.values(draft).some(d=>d.checked)&&!confirm('Обновить остатки с сервера? Введённые значения останутся, но при конфликте потребуется сверить их.'))return;await load();}
 if(a==='view'){view=btn.dataset.view;paint();}
 if(a==='select'){
  if(selected!==btn.dataset.id){
   if(Object.keys(draft).length&&!confirm('Перейти к другому складу без сохранения введённых значений?'))return;
   selected=btn.dataset.id;draft={};
  }
  view='masters';paint();
 }
 if(a==='material')materialForm(btn.dataset.id);
 if(a==='assign')assignForm(btn.dataset.person);
 if(a==='category')dialog('Новая категория','<label>Название<input name="name" required maxlength="100"></label>',f=>command({op:'category',name:f.get('name')}));
 if(a==='settings')dialog('Периодичность проверки',`<label>Раз в сколько дней<input name="days" type="number" min="1" max="365" required value="${w.interval_days}"></label>`,f=>command({op:'settings',warehouse_id:w.id,version:w.version,interval_days:Number(f.get('days'))}));
 if(a==='dismiss-save'){saveNotice=null;paint();return;}
 if(a==='reconcile-stock'){await load(true);return;}
 if(a==='save'){
  const s=session(w);
  const items=rows(w).filter(r=>draft[r.m.id]?.checked&&(!s||s.required_ids.includes(r.m.id))).map(r=>{
   const entry=draft[r.m.id],quantity=number(entry.quantity);
   if(['шт.','упаковка'].includes(r.m.unit)&&!Number.isInteger(quantity))throw Error('Введите целое количество для «'+r.m.name+'»');
   return {...entry.baseline,quantity};
  });
  if(!items.length)throw Error('Отметьте хотя бы один проверенный остаток');
  if(s)await command({op:'inventory',warehouse_id:w.id,session_id:s.id,items});
  else await command({op:'start',warehouse_id:w.id},false,items);
 }
 if(a==='correct'){const r=rows(w).find(r=>r.m.id===btn.dataset.id);dialog('Исправить остаток',`<label>Количество (${escape(r.m.unit)})<input name="quantity" inputmode="decimal" required value="${escape(r.b?.quantity??'')}"></label><label>Причина<textarea name="reason" required minlength="3" maxlength="1000"></textarea></label>`,f=>command({op:'correct',warehouse_id:w.id,reason:f.get('reason'),items:[line(r,f.get('quantity'))]}));}
 if(a==='material-balances'){const m=data.materials.find(m=>m.id===btn.dataset.id);const d=dialog(m.name,data.warehouses.map(w=>{const r=rows(w).find(r=>r.m.id===m.id);return r?`<p>${escape(own(w))}: ${fmt(r.b?.quantity)} ${escape(m.unit)}</p>`:'';}).join(''),async()=>{});d.querySelector('[type=submit]').hidden=true;}
 if(a==='history-more'){const events=[...data.history,...older],next=await rpc('crm_stock_read',{p_before:events.at(-1).id});older.push(...next.history);paint();}
 }catch(err){
  error=err.message;
  if(a==='save'&&!saveNotice&&!pending)saveNotice={type:'error',title:'Остатки не сохранены',text:err.message};
  paint();
 }}
 global.CrmWarehouse={mount,number,status,escape};
 global.addEventListener?.('beforeunload',e=>{if(pending||Object.keys(draft).length){e.preventDefault();e.returnValue='';}});
})(globalThis);
