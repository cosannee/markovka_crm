import fs from 'node:fs';
import assert from 'node:assert/strict';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const root=new URL('../',import.meta.url),source=fs.readFileSync(new URL('index.html',root),'utf8');
const css=[...source.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map(m=>m[1]).join('\n');
const code=source.slice(source.indexOf('const FABRIC_PALETTES='),source.indexOf('let _searchDebounce='));
assert.ok(code.length>1000);
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try{
const page=await browser.newPage({viewport:{width:390,height:660},isMobile:true,hasTouch:true});
const errors=[];page.on('pageerror',e=>errors.push(e.message));let fail=false;
await page.route('http://palette.test/**',async route=>{
 const path=new URL(route.request().url()).pathname;
 if(path.startsWith('/fabrics/')){await new Promise(r=>setTimeout(r,150));return fail?route.abort():route.fulfill({contentType:'image/jpeg',body:fs.readFileSync(new URL(path.slice(1),root))});}
 return route.fulfill({contentType:'text/html',body:`<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${css}</style><button onclick="openFabricPalette(0)">Палитра</button><script>const tab='master';function canSeeSharedFabricPalette(){return true}function uiText(s){return s}function renderTab(){}${code}</script>`});
});
await page.goto('http://palette.test/');await page.getByText('Палитра',{exact:true}).tap();
for(let i=0;i<4;i++){
 await page.locator('#fabric-dialog-tabs [data-group="'+i+'"]').tap();
 await page.waitForFunction(()=>document.getElementById('fabric-load-status').hidden);
 assert.ok(await page.locator('#fabric-full-image').evaluate(i=>i.complete&&i.naturalWidth>0));
 assert.equal(await page.locator('#fabric-dialog-tabs [aria-pressed=true]').getAttribute('data-group'),String(i));
}
await page.getByRole('button',{name:'Увеличить',exact:true}).tap();
assert.ok(await page.locator('#fabric-full-image').evaluate(i=>i.classList.contains('zoomed')));
await page.screenshot({path:'/private/tmp/markovka-stock-test/palette-mobile.png'});
await page.getByRole('button',{name:'Закрыть',exact:true}).tap();
assert.equal(await page.locator('#fabric-modal').count(),0);
fail=true;await page.evaluate(()=>FABRIC_PALETTES[0].image+='?failure-test');await page.getByText('Палитра',{exact:true}).tap();
await page.getByRole('button',{name:'Повторить',exact:true}).waitFor();
fail=false;await page.getByRole('button',{name:'Повторить',exact:true}).tap();
await page.waitForFunction(()=>document.getElementById('fabric-load-status').hidden);
await page.locator('#fabric-dialog-tabs [data-group="3"]').tap();
await page.locator('#fabric-dialog-tabs [data-group="1"]').tap();
await page.waitForFunction(()=>document.getElementById('fabric-load-status').hidden);
assert.ok((await page.locator('#fabric-full-image').getAttribute('src')).endsWith('5-8.jpg'));
await page.getByRole('button',{name:'Закрыть',exact:true}).tap();
assert.deepEqual(errors,[]);console.log('PASS four groups, zoom, close/reopen, failed load/retry, rapid switching on mobile');
}finally{await browser.close()}
