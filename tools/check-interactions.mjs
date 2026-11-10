// Drives the page in headless Chrome and checks its interactive parts: the Library search, the How it works tabs,
// the questions, the screenshot viewer (with the tall Scrolling Capture), the download links on and off a Mac, and
// that every image loads. Uses the taste-skill's Chrome driver (TASTE_SKILL, or its default install).
// Usage: node tools/check-interactions.mjs   (exits 1 if any check fails)
import { createServer } from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { join, extname, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const skill = process.env.TASTE_SKILL || join(homedir(), '.claude/plugins/cache/taste-skill/taste-skill/2.1.4/skills/taste-skill');
const { Browser, sleep } = await import(join(skill, 'scripts/lib/cdp.mjs'));

const types = { '.html': 'text/html', '.jpg': 'image/jpeg', '.png': 'image/png', '.woff2': 'font/woff2', '.xml': 'application/xml' };
const server = createServer((req, res) => {
  const path = join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/\/$/, '/index.html'));
  if (!path.startsWith(root) || !existsSync(path)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(path)] || 'application/octet-stream' });
  res.end(readFileSync(path));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

let failed = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`); if (!ok) failed++; };

const browser = await Browser.launch();
try {
  const page = await browser.newPage({ width: 1440, height: 900 });
  await page.goto(url);

  const search = (q) => page.eval((q) => {
    const input = document.getElementById('q');
    input.value = q; input.dispatchEvent(new Event('input'));
    return { count: document.getElementById('count').textContent, titles: [...document.querySelectorAll('#rows .result b')].map((b) => b.textContent), more: document.querySelector('#rows .more')?.textContent || '', empty: !!document.querySelector('#rows .empty'), marks: [...document.querySelectorAll('#rows mark')].map((m) => m.textContent), injected: document.querySelectorAll('#rows img[src="x"]').length };
  }, q);
  let r = await search('routes walked');
  check('search "routes walked"', r.count === '4 of 10 sample captures match' && r.titles.length === 4 && r.marks.length === 4 && r.marks.every((m) => m.toLowerCase() === 'routes walked'), JSON.stringify(r));
  r = await search('app:safari subscribe');
  check('search "app:safari subscribe"', r.count === '2 of 10 sample captures match' && r.titles.join() === 'Full page,Home page', JSON.stringify(r));
  r = await search('app:photos');
  check('search "app:photos"', r.count === '1 of 10 sample captures matches' && r.titles.join() === 'Field kit', JSON.stringify(r));
  r = await search('travel');
  check('search "travel" finds the tag', r.titles.join() === 'Lake at dawn', JSON.stringify(r));
  r = await search('northern lights');
  check('search "northern lights" finds the title', r.titles.join() === 'Northern lights', JSON.stringify(r));
  r = await search('');
  check('an empty search shows four and counts the rest', r.titles.length === 4 && r.more === 'And 6 more', JSON.stringify(r));
  r = await search('<img src=x onerror=alert(1)>');
  check('search escapes markup and shows the empty state', r.empty && r.titles.length === 0 && r.injected === 0, JSON.stringify(r));
  r = await page.eval(() => { document.querySelector('.try button[data-q="backpack"]').click(); return { value: document.getElementById('q').value, titles: [...document.querySelectorAll('#rows .result b')].map((b) => b.textContent) }; });
  check('example button refills the search', r.value === 'backpack' && r.titles.join() === 'Slow Roads walkthrough,Full page', JSON.stringify(r));

  const tabState = () => page.eval(() => ({
    selected: [...document.querySelectorAll('[role=tab]')].map((t) => t.getAttribute('aria-selected')).join(),
    tabindex: [...document.querySelectorAll('[role=tab]')].map((t) => t.tabIndex).join(),
    shown: [...document.querySelectorAll('[role=tabpanel]')].filter((p) => !p.hidden).map((p) => p.id).join(),
    focus: document.activeElement.id,
  }));
  await page.eval(() => document.getElementById('tab-3').click());
  r = await tabState();
  check('a tab shows its own panel', r.selected === 'false,false,true,false' && r.tabindex === '-1,-1,0,-1' && r.shown === 'panel-3', JSON.stringify(r));
  await page.eval(() => document.getElementById('tab-3').dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })));
  r = await tabState();
  check('ArrowRight moves to the next tab', r.shown === 'panel-4' && r.focus === 'tab-4', JSON.stringify(r));
  await page.eval(() => document.getElementById('tab-4').dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true })));
  r = await tabState();
  check('Home goes back to the first tab', r.shown === 'panel-1' && r.focus === 'tab-1', JSON.stringify(r));

  r = await page.eval(() => { const d = document.querySelectorAll('.faq details'); d[1].querySelector('summary').click(); return { n: d.length, open: [...d].map((x) => x.open).join() }; });
  check('a question opens its answer', r.n === 6 && r.open === 'false,true,false,false,false,false', JSON.stringify(r));

  await page.eval(() => [...document.querySelectorAll('a.shot')].find((a) => a.textContent.includes('Scrolling')).click());
  await sleep(1200);
  r = await page.eval(() => { const m = document.querySelector('.viewer-media'); return { open: document.getElementById('viewer').open, src: m.querySelector('img').getAttribute('src'), tall: m.classList.contains('tall'), scrolls: m.scrollHeight > m.clientHeight * 2, count: document.getElementById('v-count').textContent }; });
  check('the Scrolling Capture opens as a page you can scroll', r.open && r.src.endsWith('scrolling-capture-full.jpg') && r.tall && r.scrolls && r.count === '4 of 14', JSON.stringify(r));
  r = await page.eval(() => { const m = document.querySelector('.viewer-media'); m.scrollTop = 900; document.getElementById('v-next').click(); return { name: document.getElementById('v-name').textContent, tall: m.classList.contains('tall'), top: m.scrollTop }; });
  check('the next screen opens at its top', r.name === 'The editor' && !r.tall && r.top === 0, JSON.stringify(r));
  r = await page.eval(() => { document.getElementById('v-close').click(); return document.getElementById('viewer').open; });
  check('the viewer closes', r === false);

  const links = await page.eval(() => [...document.querySelectorAll('a[href*="releases/download"]')].map((a) => a.href));
  check('the three download links name one DMG', links.length === 3 && new Set(links).size === 1 && /\/releases\/download\/v(\d+\.\d+\.\d+)\/Sukusho-\1\.dmg$/.test(links[0]), links.join(' '));
  // Lazy images below the fold haven't loaded yet, so fetch every picture the page names instead.
  const missing = await page.eval(async () => {
    const srcs = new Set([...document.querySelectorAll('img[src]')].map((i) => i.getAttribute('src')));
    for (const m of document.documentElement.innerHTML.matchAll(/assets\/img\/[a-z0-9-]+\.(?:jpg|png)/g)) srcs.add(m[0]);
    const bad = [];
    for (const s of srcs) { const r = await fetch(s); if (!r.ok) bad.push(s); }
    return bad;
  });
  check('every image loads', missing.length === 0, missing.join(' '));

  // An iPhone: the download buttons hand the link on, and nothing scrolls sideways.
  const phone = await browser.newPage({ width: 390, height: 844, mobile: true });
  await phone.send('Emulation.setUserAgentOverride', { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1' });
  await phone.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await phone.goto(url);
  r = await phone.eval(() => ({ cta: document.querySelector('.hero .cta').firstChild.textContent, status: document.querySelector('.hero .status').hidden ? '' : document.querySelector('.hero .status').textContent, wide: document.documentElement.scrollWidth }));
  check('off a Mac the buttons send the link on', /^(Send the link to your Mac|Copy the download link)$/.test(r.cta) && r.status.startsWith('Sukusho runs on Macs') && r.wide === 390, JSON.stringify(r));
} finally {
  await browser.close();
  server.close();
}
process.exit(failed ? 1 : 0);
