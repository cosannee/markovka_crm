import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE);
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try{
  const page=await browser.newPage({viewport:{width:390,height:844}});
  await page.goto(process.env.CRM_URL||'http://127.0.0.1:4173',{waitUntil:'domcontentloaded'});
  await page.evaluate(()=>{
    role='director';realRole='director';isPreviewMode=false;initialDataPending=false;initialDataError=false;
    crmProfile={id:'director-nav-test',role:'director',name:'Даша',label:'Создатель · мастер',masterName:'Даша'};
    orders=[];tasks=[];finance=[];financeTableOk=true;
    document.getElementById('login').style.display='none';document.getElementById('app').style.display='flex';
    document.getElementById('h-user-name').textContent='Даша';document.getElementById('h-role-lbl').textContent='Создатель · мастер';
    renderTab('more');
  });
  const dock=page.locator('#tabs-bar .tab:visible');
  assert.deepEqual(await dock.allTextContents(),['Заказы','Неделя','Ещё']);
  const more=page.locator('.more-item:visible');
  const labels=await more.locator('.more-item-title').allTextContents();
  assert.ok(labels.includes('Обзор'));
  assert.ok(labels.includes('Выплаты'));
  assert.equal(await page.locator('.more-item[data-nav="payments"] .more-item-sub').textContent(),'Выплаты по заказам и сотрудникам');
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  await page.screenshot({path:'/private/tmp/markovka-director-navigation.png',fullPage:true});
  console.log('PASS Dasha mobile dock and More navigation');
}finally{await browser.close();}
