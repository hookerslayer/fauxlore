const RULES_URL = new URL('./docs/rules.md', import.meta.url);
const LIBRARIES = [
  ['marked', 'assets/vendor/marked.umd.js'],
  ['DOMPurify', 'assets/vendor/purify.min.js']
];
const STORAGE_KEY = 'fauxlore-rules-chapter';
let rendererPromise;

function loadScript(globalName, source) {
  if (window[globalName]) return Promise.resolve(window[globalName]);
  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = source;
    script.async = true;
    script.onload = () => window[globalName]
      ? resolve(window[globalName])
      : reject(new Error('Не удалось открыть библиотеку чтения правил.'));
    script.onerror = () => reject(new Error('Не удалось загрузить библиотеку чтения правил.'));
    document.head.append(script);
  });
}

function getRenderer() {
  if (!rendererPromise) {
    rendererPromise = Promise.all(LIBRARIES.map(([name, source]) => loadScript(name, source)))
      .then(([marked, purifier]) => markdown => purifier.sanitize(marked.parse(markdown, { gfm: true }), { USE_PROFILES: { html: true } }))
      .catch(error => { rendererPromise = null; throw error; });
  }
  return rendererPromise;
}

function splitChapters(markdown) {
  const headings = [...markdown.matchAll(/^## ([1-9]\d*)\. (.+)$/gm)];
  if (!headings.length) throw new Error('В документе не найдены главы правил.');
  const pages = [{ key: 'overview', title: 'Обзор', markdown: markdown.slice(0, headings[0].index).trim() }];
  headings.forEach((heading, index) => {
    const end = headings[index + 1]?.index ?? markdown.length;
    pages.push({ key: heading[1], title: heading[2].trim(), markdown: markdown.slice(heading.index, end).trim() });
  });
  return pages;
}

function slug(text) {
  return String(text).toLocaleLowerCase('ru-RU')
    .replace(/[^\p{L}\p{N}_\- ]/gu, '')
    .replace(/\s+/g, '-');
}

function rememberedChapter() {
  try { return sessionStorage.getItem(STORAGE_KEY) || 'overview'; }
  catch { return 'overview'; }
}

function rememberChapter(key) {
  try { sessionStorage.setItem(STORAGE_KEY, key); }
  catch { /* Reading still works when storage is unavailable. */ }
}

export async function renderRules(host) {
  host.innerHTML = `<section class="rules-reader">
    <header class="rules-reader-header">
      <div><h2>Материалы проекта</h2><p>Действующие правила Fauxlore</p></div>
      <button type="button" class="rules-refresh">Обновить</button>
    </header>
    <div class="rules-reader-layout">
      <nav class="rules-reader-nav" aria-label="Главы правил"></nav>
      <label class="rules-reader-picker"><span>Раздел правил</span><select aria-label="Раздел правил"></select></label>
      <article class="rules-reader-article" aria-live="polite"><p>Загружаю правила…</p></article>
    </div>
  </section>`;
  const nav = host.querySelector('.rules-reader-nav');
  const picker = host.querySelector('.rules-reader-picker select');
  const article = host.querySelector('.rules-reader-article');
  const refresh = host.querySelector('.rules-refresh');
  let pages = [];
  let currentKey = rememberedChapter();
  let requestId = 0;

  async function showPage(key, anchor = '') {
    const page = pages.find(item => item.key === key) || pages[0];
    if (!page) return;
    currentKey = page.key;
    rememberChapter(currentKey);
    nav.querySelectorAll('button').forEach(button => {
      const selected = button.dataset.chapter === currentKey;
      button.classList.toggle('active', selected);
      if (selected) button.setAttribute('aria-current', 'page');
      else button.removeAttribute('aria-current');
    });
    picker.value = currentKey;
    const renderMarkdown = await getRenderer();
    if (!host.isConnected || currentKey !== page.key) return;
    const template = document.createElement('template');
    template.innerHTML = renderMarkdown(page.markdown);
    const used = new Map();
    template.content.querySelectorAll('h1,h2,h3,h4,h5').forEach(heading => {
      const base = slug(heading.textContent);
      const count = used.get(base) || 0;
      used.set(base, count + 1);
      heading.id = `rules-${base}${count ? '-' + count : ''}`;
    });
    template.content.querySelectorAll('table').forEach(table => {
      const wrap = document.createElement('div');
      wrap.className = 'rules-table-wrap';
      table.before(wrap);
      wrap.append(table);
    });
    template.content.querySelectorAll('a[href]').forEach(link => {
      if (/^https?:/i.test(link.getAttribute('href') || '')) {
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
      }
    });
    article.replaceChildren(template.content.cloneNode(true));
    if (anchor) {
      const heading = [...article.querySelectorAll('[id]')].find(node => node.id === `rules-${anchor}`);
      heading?.scrollIntoView({ block: 'start' });
    } else host.closest('.app-page')?.scrollTo({ top: 0 });
  }

  function populateNavigation() {
    nav.replaceChildren();
    picker.replaceChildren();
    pages.forEach(page => {
      const button = document.createElement('button');
      button.type = 'button';
      button.dataset.chapter = page.key;
      button.textContent = page.key === 'overview' ? page.title : `${page.key}. ${page.title}`;
      button.addEventListener('click', () => void showPage(page.key));
      nav.append(button);
      picker.add(new Option(button.textContent, page.key));
    });
    picker.onchange = () => void showPage(picker.value);
  }

  async function load() {
    const id = ++requestId;
    refresh.disabled = true;
    if (!pages.length) article.innerHTML = '<p>Загружаю правила…</p>';
    try {
      const response = await fetch(RULES_URL, { cache: 'no-store' });
      if (!response.ok) throw new Error(`Не удалось загрузить правила: HTTP ${response.status}`);
      const markdown = await response.text();
      if (!host.isConnected || id !== requestId) return;
      pages = splitChapters(markdown);
      populateNavigation();
      await showPage(currentKey);
    } catch (error) {
      if (host.isConnected && id === requestId) {
        article.replaceChildren();
        const message = document.createElement('p');
        message.textContent = error.message || 'Не удалось открыть правила.';
        article.append(message);
      }
    } finally {
      if (host.isConnected && id === requestId) refresh.disabled = false;
    }
  }

  article.addEventListener('click', event => {
    const link = event.target.closest('a[href^="#"]');
    if (!link) return;
    const anchor = decodeURIComponent(link.getAttribute('href').slice(1));
    const page = pages.find(item => slug(`${item.key}. ${item.title}`) === anchor);
    if (page) {
      event.preventDefault();
      void showPage(page.key);
      return;
    }
    const heading = [...article.querySelectorAll('[id]')].find(node => node.id === `rules-${anchor}`);
    if (heading) {
      event.preventDefault();
      heading.scrollIntoView({ block: 'start' });
    }
  });
  refresh.addEventListener('click', () => void load());
  await load();
}
