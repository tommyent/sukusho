// Drives the page in headless Chrome and checks its interactive parts: the Library search, the switches, the
// stage slider and the footer name's fit. Uses the taste-skill's Chrome driver (TASTE_SKILL, or its default
// install). Usage: node tools/check-interactions.mjs   (exits 1 on the first failed check)
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
  await page.eval(() => window.__errors = []);

  const search = (q) => page.eval((q) => {
    const input = document.getElementById('q');
    input.value = q; input.dispatchEvent(new Event('input'));
    return { count: document.getElementById('count').textContent, titles: [...document.querySelectorAll('#rows .result b')].map((b) => b.textContent), empty: !!document.querySelector('.results-empty'), marks: [...document.querySelectorAll('#rows mark')].map((m) => m.textContent) };
  }, q);
  let r = await search('routes walked');
  check('search "routes walked"', r.count === '4 of 10 captures' && r.titles.length === 3 && r.marks.every((m) => m.toLowerCase() === 'routes walked'), JSON.stringify(r));
  r = await search('app:safari subscribe');
  check('search "app:safari subscribe"', r.count === '2 of 10 captures' && r.titles.join() === 'Full page,Home page', JSON.stringify(r));
  r = await search('app:photos');
  check('search "app:photos"', r.count === '1 of 10 captures' && r.titles.join() === 'Field kit', JSON.stringify(r));
  r = await search('travel');
  check('search "travel" finds the tag', r.titles.join() === 'Lake at dawn', JSON.stringify(r));
  r = await search('northern lights');
  check('search "northern lights" finds the title', r.titles.join() === 'Northern lights', JSON.stringify(r));
  r = await search('<img src=x onerror=alert(1)>');
  check('search escapes markup and shows the empty state', r.empty && r.titles.length === 0, JSON.stringify(r));
  r = await page.eval(() => { document.querySelector('.examples button[data-q="backpack"]').click(); return { value: document.getElementById('q').value, titles: [...document.querySelectorAll('#rows .result b')].map((b) => b.textContent) }; });
  check('example button refills the search', r.value === 'backpack' && r.titles.join() === 'Slow Roads walkthrough,Full page', JSON.stringify(r));

  r = await page.eval(() => {
    const t = document.querySelectorAll('.toggle')[1], band = t.closest('.band');
    const before = [t.getAttribute('aria-checked'), band.dataset.on];
    t.click();
    const after = [t.getAttribute('aria-checked'), band.dataset.on];
    t.click();
    return { before, after, back: [t.getAttribute('aria-checked'), band.dataset.on] };
  });
  check('switch turns on and off', r.before.join() === 'false,false' && r.after.join() === 'true,true' && r.back.join() === 'false,false', JSON.stringify(r));

  await page.eval(() => { const s = document.getElementById('stage'); s.value = 2; s.dispatchEvent(new Event('input')); });
  await sleep(400);
  r = await page.eval(() => ({ title: document.getElementById('stage-title').textContent, img: document.getElementById('stage-img').getAttribute('src'), current: document.querySelector('#stage-names [aria-current]').textContent, currents: document.querySelectorAll('#stage-names [aria-current]').length, fill: document.getElementById('stage-fill').style.getPropertyValue('--filled'), valuetext: document.getElementById('stage').getAttribute('aria-valuetext') }));
  check('slider shows the third stage', r.title === 'Then send the link' && r.img.endsWith('share-page.jpg') && r.current === 'Share' && r.currents === 1 && r.fill.startsWith('66.6') && r.valuetext === 'Share', JSON.stringify(r));
  await page.eval(() => document.querySelector('#stage-names li[data-i="3"]').click());
  await sleep(400);
  r = await page.eval(() => document.getElementById('stage-title').textContent);
  check('a stage name moves the slider', r === 'Last, read the replies', r);

  r = await page.eval(() => { const n = document.querySelector('.close-name'), f = n.parentElement, pad = parseFloat(getComputedStyle(f).paddingLeft); return { text: n.scrollWidth, box: f.clientWidth - 2 * pad }; });
  check('footer name fills the content width at 1440', Math.abs(r.text - r.box) <= 4, JSON.stringify(r));

  const links = await page.eval(() => [...document.querySelectorAll('a[href*="releases/download"]')].map((a) => a.href));
  check('download links name the 1.2.0 DMG', links.length === 2 && links.every((h) => h === 'https://github.com/tommyent/sukusho/releases/download/v1.2.0/Sukusho-1.2.0.dmg'), links.join(' '));
  // Lazy images below the fold haven't loaded yet, so fetch every picture the page names instead.
  const missing = await page.eval(async () => {
    const srcs = new Set([...document.querySelectorAll('img')].map((i) => i.getAttribute('src')));
    for (const m of document.documentElement.innerHTML.matchAll(/assets\/img\/[a-z0-9-]+\.jpg/g)) srcs.add(m[0]);
    const bad = [];
    for (const s of srcs) { const r = await fetch(s); if (!r.ok) bad.push(s); }
    return bad;
  });
  check('every image loads', missing.length === 0, missing.join(' '));
} finally {
  await browser.close();
  server.close();
}
process.exit(failed ? 1 : 0);
