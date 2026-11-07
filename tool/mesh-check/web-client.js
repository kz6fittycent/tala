const { chromium } = require('playwright');
(async () => {
  const [token, seconds, who='bob'] = process.argv.slice(2);
  const b = await chromium.launch({ args: ['--use-fake-device-for-media-stream','--use-fake-ui-for-media-stream','--no-sandbox','--disable-features=WebRtcHideLocalIpsWithMdns'] });
  const ctx = await b.newContext({ permissions: ['camera','microphone'], viewport: {width:1200,height:800}, userAgent:'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' });
  const p = await ctx.newPage();
  p.on('console', m => { const t=m.text(); if (/Starting call|sending offer|Remove disconnected|No offer/i.test(t)) console.log('web:', t.slice(0,90)); });
  console.log('start'); await p.goto('http://127.0.0.1:8088/index.php/login'); console.log('login page', await p.title());
  await p.fill('#user',who); await p.fill('#password','mesh-test-'+who+'-pass');
  await p.click('button[type=submit]');
  await p.waitForURL(u => !u.toString().includes('/login'), {timeout:60000});
  console.log('logged in'); await p.goto('http://127.0.0.1:8088/index.php/call/'+token); console.log('call page');
  const join = async () => {
    for (let i=0;i<45;i++) {
      if (i==15) { console.log('buttons:', (await p.locator('button').allInnerTexts()).join('|').slice(0,500)); await p.screenshot({path:'/w/bob.png'}); }
      const dlg = p.locator('.media-settings button, [role=dialog] button').filter({hasText:/^\s*(Join call|Start call)\s*$/});
      if (await dlg.count()) { await dlg.first().click({timeout:3000}).catch(()=>{}); console.log('clicked in dialog'); return; }
      const top = p.locator('button').filter({hasText:/^\s*(Join call|Start call)\s*$/});
      if (await top.count()) await top.first().click({timeout:3000}).catch(()=>{});
      await p.waitForTimeout(1000);
    }
    console.log('never found join', (await p.locator('button').allInnerTexts()).join('|').slice(0,400));
  };
  await join();
  const stats = async () => p.evaluate(async () => {
    const w = window.OCA?.Talk?.SimpleWebRTC?.webrtc; if (!w) return 'no webrtc';
    const out=[];
    for (const peer of w.peers||[]) {
      const r = await peer.pc.getStats(); let a=[];
      r.forEach(s => { if (s.type==='inbound-rtp') a.push('in '+s.kind+' '+s.bytesReceived+(s.framesDecoded!==undefined?' frames '+s.framesDecoded:'')); if (s.type==='outbound-rtp') a.push('out '+s.kind+' '+s.bytesSent); });
      out.push(peer.pc.connectionState+' '+peer.pc.iceConnectionState+': '+a.join(', '));
    }
    return out.join(' | ')||'no peers';
  });
  const end = Date.now()+seconds*1000;
  while (Date.now()<end) { await p.waitForTimeout(5000); console.log('web stats:', await stats()); }
  await p.screenshot({path:'/w/bob.png'}).catch(()=>{});
  await b.close();
})().catch(e => { console.error('FAIL', e.message.slice(0,300)); process.exit(1); });
