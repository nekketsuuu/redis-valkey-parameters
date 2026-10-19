const query = new URLSearchParams(location.search);
const tableOnly = query.get('tableonly') === 'true';
const PICKER_INDICATOR_WIDTH = 24;
const configCache = new Map();
let availableVersions = [];
let rendering = Promise.resolve();

const el = (id) => document.getElementById(id);

function createElement(type, attrs = {}, text) {
  const e = document.createElement(type);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  if (text !== undefined) e.textContent = text;
  return e;
}

async function fetchJSON(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`${path}: ${res.status}`);
  return res.json();
}

function loadConfig(id) {
  if (!configCache.has(id)) configCache.set(id, fetchJSON(`json/${id}/config.json`));
  return configCache.get(id);
}

function availableIds() {
  return availableVersions.map((v) => v.id);
}

function compareVersions(a, b) {
  const [pa, pb] = [a, b].map((id) => id.split('-')[1].split('.').map(Number));
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function latestVersion(ids) {
  return ids.toSorted(compareVersions).at(-1);
}

function resolveVersion(input) {
  const ids = availableIds();
  return ids.includes(input) ? input : latestVersion(ids.filter((id) => id.startsWith(`${input}.`)));
}

function defaultVersions() {
  const products = [...new Set(availableIds().map((id) => id.split('-')[0]))];
  return products.map((product) => latestVersion(availableIds().filter((id) => id.startsWith(`${product}-`))));
}

function versionInputs() {
  return [...document.getElementsByName('version')];
}

function addInput(value = '') {
  const input = createElement('input', { name: 'version', type: 'search', list: 'version_list' });
  input.value = value;
  input.addEventListener('change', redisplay);
  input.addEventListener('input', () => {
    if (availableIds().includes(input.value)) redisplay();
  });
  // Browsers filter datalist options by the current value, so clear it while the list is opened from the indicator.
  input.addEventListener('mousedown', (e) => {
    if (input.value === '' || e.offsetX < input.clientWidth - PICKER_INDICATOR_WIDTH) return;
    input.placeholder = input.value;
    input.value = '';
  });
  input.addEventListener('blur', () => {
    if (input.value === '' && input.placeholder !== '') input.value = input.placeholder;
    input.placeholder = '';
  });
  el('versions').appendChild(input);
}

function applyDiffOnly() {
  el('params').classList.toggle('only-diff', el('only_difference').checked);
}

function setLocation() {
  const q = new URLSearchParams(location.search);
  ['vers', 'diff', 'modules'].forEach((key) => q.delete(key));
  const vers = versionInputs().map((input) => input.value).filter((v) => v !== '').join(',');
  if (vers) q.set('vers', vers);
  if (el('only_difference').checked) q.set('diff', 'true');
  if (el('include_modules').checked) q.set('modules', 'true');
  const search = q.toString().replaceAll('%2C', ',');
  history.replaceState(null, '', search ? `?${search}` : location.pathname);
}

function redisplay() {
  rendering = rendering.then(render).catch((e) => alert(e.message));
}

async function render() {
  el('in-progress').style.display = 'block';
  try {
    const ids = [];
    const inputs = versionInputs();
    inputs.forEach((input, i) => {
      const value = (input.value = input.value.trim());
      if (value === '') {
        if (i < inputs.length - 1) input.remove();
        return;
      }
      const id = resolveVersion(value);
      input.classList.toggle('invalid-version', !id);
      if (id) ids.push(id);
    });
    if (versionInputs().at(-1)?.value !== '') addInput();
    setLocation();
    displayTable(await Promise.all(ids.map(loadConfig)));
  } finally {
    el('in-progress').style.display = 'none';
  }
}

function displayTable(configs) {
  const includeModules = el('include_modules').checked;
  const columns = configs.map((config) => ({
    config,
    values: (includeModules && config.with_modules) || config.base,
  }));
  const names = [...new Set(columns.flatMap((c) => Object.keys(c.values)))].sort();

  const table = createElement('table', { id: 'param_table' });
  const header = createElement('tr');
  header.appendChild(createElement('th', {}, 'Parameter'));
  for (const { config } of columns) {
    const th = createElement('th', {}, `${config.product} ${config.version}`);
    if (includeModules && config.modules) th.title = config.modules.map((m) => `${m.name} ${m.ver}`).join('\n');
    header.appendChild(th);
  }
  table.appendChild(header);
  for (const name of names) table.appendChild(buildRow(name, columns));
  el('params').replaceChildren(table);
}

function buildRow(name, columns) {
  const values = columns.map((c) => c.values[name]);
  const tr = createElement('tr');
  if (new Set(values).size === 1) tr.className = 'same-value';
  tr.appendChild(buildNameCell(name, columns));

  let prevValue;
  let prevWords = null;
  values.forEach((value, i) => {
    const td = createElement('td', { class: 'parameter-value' });
    let words = null;
    if (value === undefined) {
      td.classList.add('unexist');
    } else {
      words = appendWords(td, value);
      if (i > 0 && prevValue !== value) {
        td.classList.add('difference');
        if (prevWords && /\s/.test(prevValue + value)) markWordDiff(prevWords, words);
      }
    }
    tr.appendChild(td);
    prevValue = value;
    prevWords = words;
  });
  return tr;
}

function buildNameCell(name, columns) {
  const td = createElement('td', { class: 'parameter-name' });
  const doc = columns.map((c) => c.config.docs[name]).filter(Boolean).at(-1);
  if (doc) {
    td.appendChild(createElement('a', { href: doc, rel: 'noreferrer noopener', target: '_blank' }, name));
  } else {
    td.textContent = name;
  }
  return td;
}

function appendWords(td, value) {
  const words = [];
  for (const piece of value.split(/(\s+)/).filter((s) => s !== '')) {
    if (/^\s+$/.test(piece)) {
      td.appendChild(document.createTextNode(piece));
    } else {
      const span = createElement('span', {}, piece);
      words.push(span);
      td.appendChild(span);
    }
  }
  return words;
}

function markWordDiff(prevWords, words) {
  const a = prevWords.map((s) => s.textContent);
  const b = words.map((s) => s.textContent);
  const lcs = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      prevWords[i++].classList.add('del');
    } else {
      words[j++].classList.add('add');
    }
  }
  for (; i < a.length; i++) prevWords[i].classList.add('del');
  for (; j < b.length; j++) words[j].classList.add('add');
}

async function main() {
  availableVersions = await fetchJSON('json/versions.json');
  if (!tableOnly) {
    el('header').hidden = false;
    el('footer').hidden = false;
  }

  const datalist = createElement('datalist', { id: 'version_list' });
  for (const { id, released_at } of availableVersions) {
    datalist.appendChild(createElement('option', { value: id, label: released_at }));
  }
  el('versions').appendChild(datalist);

  const diff = el('only_difference');
  diff.checked = query.get('diff') === 'true';
  diff.addEventListener('change', () => {
    applyDiffOnly();
    setLocation();
  });

  const modules = el('include_modules');
  modules.checked = query.get('modules') === 'true';
  modules.addEventListener('change', redisplay);

  const vers = query.get('vers')?.split(',').map((v) => v.trim()).filter(Boolean) ?? defaultVersions();
  vers.forEach((v) => addInput(v));
  addInput();
  applyDiffOnly();
  redisplay();
}

main().catch((e) => alert(e.message));
