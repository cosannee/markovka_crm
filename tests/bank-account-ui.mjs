import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE);
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try{
  const page=await browser.newPage({viewport:{width:390,height:1000}});
  await page.goto(process.env.CRM_URL||'http://127.0.0.1:4173',{waitUntil:'domcontentloaded'});
  const state=await page.evaluate(()=>{
    role='director';realRole='director';isPreviewMode=false;financeTableOk=true;initialDataPending=false;orders=[];tasks=[];
    crmProfile={id:'ui-test',role:'director',name:'Даша',masterName:'Даша'};
    finance=[
      {id:'d',kind:'account',name:'Озон Банк Даша',type:'bank',owner:'dasha',startBalance:12000,startDate:'2026-11-01',ord:0,archived:false},
      {id:'s',kind:'account',name:'Озон Банк Саша',type:'bank',owner:'sasha',startBalance:8000,startDate:'2026-11-01',ord:1,archived:false},
      {id:'sb',kind:'account',name:'Сбербанк',type:'bank',owner:'sasha',startBalance:5000,startDate:'2026-11-01',ord:2,archived:false},
      {id:'debt',kind:'account',name:'Долг — Цветочек',type:'debt',owner:'sasha',startBalance:3000,startDate:'2026-11-01',ord:3,archived:false},
      {id:'advent',kind:'account',name:'Предоплаты за адвенты',type:'savings',owner:'sasha',startBalance:15000,startDate:'2026-11-01',ord:4,archived:false},
      {id:'td',kind:'tx',date:'2026-11-23',type:'income',amount:1000,accountId:'d',category:'Прочий доход',created:1},
      {id:'ts',kind:'tx',date:'2026-11-23',type:'expense',amount:500,accountId:'s',category:'Материалы',created:2}
    ];
    document.getElementById('login').style.display='none';document.getElementById('app').style.display='flex';
    renderTab('bank');
    return {visible:bankAccounts().map(a=>a.name),usable:bankUsableAccounts().map(a=>a.name),text:document.body.innerText,overflow:document.documentElement.scrollWidth>innerWidth};
  });
  assert.deepEqual(state.visible,['Озон Банк Даша','Озон Банк Саша','Сбербанк','Долг — Цветочек','Предоплаты за адвенты']);
  assert.deepEqual(state.usable,['Озон Банк Даша']);
  assert.match(state.text,/Вы видите все счета и их операции/);
  assert.doesNotMatch(state.text,/⇄ Перевод/);
  assert.equal(state.overflow,false);
  await page.screenshot({path:'/private/tmp/markovka-ozon-dasha.png',fullPage:true});
  const manager=await page.evaluate(()=>{
    role='manager';realRole='manager';crmProfile={id:'ui-test-manager',role:'manager',name:'Александра'};renderTab('bank');
    return {visible:bankAccounts().map(a=>a.name),usable:bankUsableAccounts().map(a=>a.name),text:document.body.innerText};
  });
  assert.deepEqual(manager.visible,['Озон Банк Даша','Озон Банк Саша','Сбербанк','Долг — Цветочек','Предоплаты за адвенты']);
  assert.deepEqual(manager.usable,manager.visible);
  assert.match(manager.text,/⇄ Перевод/);
  console.log('PASS Dasha sees every account and can use only her own Ozon account');
}finally{await browser.close();}
