import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const read = (file) => readFile(new URL(`../${file}`, import.meta.url), 'utf8');
const [html, ui, css] = await Promise.all(['index.html', 'ui.js', 'auth-buttons.css'].map(read));
assert.ok(html.indexOf('auth-buttons.css?') > html.indexOf('research-experience.css?'), 'Brand rules must load after the theme.');

for (const [source, prefix] of [[html, 'signIn'], [ui, 'connect']]) {
  for (const [provider, label] of [['google', 'Google'], ['apple', 'Apple']]) {
    const match = source.match(new RegExp(`<button id="${prefix}${label}"[^>]*>(.*?)</button>`));
    assert.ok(match, `${prefix}${label} must retain its existing action ID.`);
    const button = match[0];
    assert.ok(button.includes('type="button"'));
    assert.ok(button.includes(`provider-button provider-button-${provider}`));
    assert.ok(button.includes(`<span>Continue with ${label}</span>`), 'Use a provider-approved visible label.');
    assert.ok(button.includes('alt=""'), 'Decorative logos must not duplicate the accessible button name.');
    const asset = button.match(/src="([^"]+)"/)[1];
    const bytes = await readFile(new URL(`../${asset}`, import.meta.url));
    assert.ok(bytes.byteLength > 0, `${asset} must be committed locally.`);
    if (provider === 'apple') {
      assert.ok(asset.includes(prefix === 'signIn' ? 'apple-logo-black' : 'apple-logo-white'), 'Apple logo must contrast with the button fill.');
      assert.ok(button.includes('width="31" height="44"'), 'Preserve the official Apple artwork and its clear space.');
    }
    if (prefix === 'connect') assert.ok(button.includes('aria-describedby="providerLinkHint"'), 'Explain account linking without changing approved branding labels.');
  }
}

assert.match(css, /height: 44px/);
assert.match(css, /gap: 12px/);
assert.match(css, /gap: 10px/);
assert.match(css, /padding: 0 12px/);
assert.match(css, /border: 1px solid #747775/);
assert.match(css, /font: 500 14px\/20px "Mirrorball Google Sans"/);
assert.match(css, /font: 500 14px\/20px -apple-system/);
assert.doesNotMatch(css, /font: 500 19px/, 'Do not mix native-size Apple labels with web-size Google labels.');
assert.match(css, /padding: 0 8%/, 'Center the Apple logo/title group while preserving its right-edge margin.');
assert.match(css, /outline: 3px solid/);
assert.match(css, /transform: none/);
assert.match(css, /provider-button\[hidden\]/, 'Brand display rules must respect hidden linked providers.');
assert.match(css, /provider-button:disabled/);
assert.match(ui, /db\.auth\.signInWithOAuth/);
assert.match(ui, /db\.auth\.linkIdentity/);
assert.match(ui, /prompt: 'select_account'/);
assert.match(ui, /button\.hidden = linked\.has\(provider\)/);
assert.doesNotMatch(html + ui, /appleid\.cdn-apple\.com|accounts\.google\.com\/gsi\/client/, 'Do not introduce an SDK that replaces the existing OAuth flow.');
assert.ok((await readFile(new URL('../Images/Auth/google-sans-medium.ttf', import.meta.url))).byteLength > 0);
assert.match(await read('Images/Auth/Google-Sans-OFL.txt'), /SIL OPEN FONT LICENSE/);

// Exercise the actual click handlers with a fake auth client: no real login
// or identity is created by this regression test.
const handlerStart = ui.indexOf("  for (const provider of ['google', 'apple']) {", ui.indexOf("db.auth.signInWithPassword"));
const handlerEnd = ui.indexOf("  document.querySelector('#signOut')", handlerStart);
assert.ok(handlerStart >= 0 && handlerEnd > handlerStart);
for (const failing of [false, true]) {
  const elements = new Map();
  const calls = [];
  const assigned = [];
  const elementFor = (selector) => {
    if (!elements.has(selector)) elements.set(selector, {
      disabled: false, textContent: '', markup: 'official artwork',
      addEventListener(event, handler) { assert.equal(event, 'click'); this.click = handler; },
    });
    return elements.get(selector);
  };
  const authResult = { data: { url: 'https://provider.example/authorize' }, error: failing ? { message: 'Test failure' } : null };
  runInNewContext(ui.slice(handlerStart, handlerEnd), {
    document: { querySelector: elementFor },
    db: { auth: {
      async signInWithOAuth(args) { calls.push({ action: 'signIn', ...args }); return authResult; },
      async linkIdentity(args) { calls.push({ action: 'link', ...args }); return authResult; },
    } },
    location: {
      origin: 'https://fkherb.github.io', pathname: '/mirrorball-fantasy/', search: '?join=example',
      href: 'https://fkherb.github.io/mirrorball-fantasy/?join=example',
      assign(url) { assigned.push(url); },
    },
    sessionStorage: { setItem() {} }, requestedView: 'standings', URL,
  });
  for (const [provider, label] of [['google', 'Google'], ['apple', 'Apple']]) {
    await elementFor(`#signIn${label}`).click();
    await elementFor(`#connect${label}`).click();
    for (const action of ['signIn', 'link']) {
      const call = calls.find(item => item.action === action && item.provider === provider);
      assert.ok(call);
      assert.equal(call.options.redirectTo, action === 'signIn'
        ? 'https://fkherb.github.io/mirrorball-fantasy/'
        : 'https://fkherb.github.io/mirrorball-fantasy/?join=example');
      assert.equal(call.options.queryParams?.prompt, provider === 'google' ? 'select_account' : undefined);
    }
    for (const prefix of ['signIn', 'connect']) {
      const button = elementFor(`#${prefix}${label}`);
      assert.equal(button.disabled, !failing, 'Prevent repeat clicks; re-enable after an auth error.');
      assert.equal(button.markup, 'official artwork', 'Loading/error states must preserve the button artwork.');
    }
    if (failing) {
      assert.match(elementFor('#signInMessage').textContent, /Test failure/);
      assert.match(elementFor('#providerLinkMessage').textContent, /Test failure/);
    }
  }
  assert.equal(assigned.length, failing ? 0 : 2);
}
console.log('Branded sign-in and identity-linking button checks passed.');
