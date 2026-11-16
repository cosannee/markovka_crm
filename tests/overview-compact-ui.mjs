import fs from 'node:fs';import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE);const s=fs.readFileSync('index.html','utf8');
const styles=[...s.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m=>m[1]).join('\n');
const code=s.slice(s.indexOf('function productionShortClient'),s.indexOf('</script>',s.indexOf('function productionShortClient')))+s.slice(s.indexOf('function tplOverviewPersonalTasks'),s.indexOf('async function setOverviewPersonalDone'));
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try{const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.setContent(`<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>${styles}</style><main id="test" style="padding:16px;max-width:900px;margin:auto"></main><script>
var role='manager',isPreviewMode=false,MASTERS=['Даша','Юлия'],tasks=[{id:'t1',text:'Проверить новые заказы',to:'Александра',from:'Александра'}],crmStorage={getItem(){return null},setItem(){}};
function myTaskName(){return 'Александра'}function sortTasksByDue(){return 0}function taskDueChip(){return '<small>Сегодня</small>'}function uiText(x){return String(x)}function fmt(x){return x+' ₽'}function isClosed(o){return o.closed}function orderTotal(o){return o.total}function jumpTo(id){window.selectedOrder=id}function productionTiles(x){return x}
${code}
const o={id:'1',num:'И123',master:'Даша',client:'Иванова Мария',total:16000,prepaid:4800};const rows=[{o,index:0,name:'Мишка',due:'2026-11-18',ready:false},{o,index:1,name:'Зайка',due:'2026-11-18',ready:false}];document.getElementById('test').innerHTML=tplOverviewPersonalTasks()+tplProductionBoard(rows)+'<select><option>Все категории</option></select>';
</script>`);
for(const width of [390,1470]){await page.setViewportSize({width,height:850});assert.equal(await page.locator('.overview-personal').getAttribute('open'),null);assert.equal(await page.locator('.production-person').getAttribute('open'),null);assert.equal(await page.locator('.production-person summary').innerText(),'Даша\nГотово 0/2');await page.locator('.production-person summary').click();assert.equal(await page.locator('.production-person .production-cell').count(),1);await page.locator('.production-cell').click();assert.equal(await page.evaluate(()=>window.selectedOrder),'1');assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.screenshot({path:'/private/tmp/markovka-stock-test/overview-compact-'+width+'.png'});await page.locator('.production-person summary').click();}
assert.deepEqual(errors,[]);console.log('PASS compact task/week defaults, toy count, grouped order, card navigation, mobile overflow');
}finally{await browser.close()}
