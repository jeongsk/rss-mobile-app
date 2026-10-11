// 리더 화면 보조 스크립트 (앱 전용 content world 에서 실행)
// - 하이라이트: 인용문 + 앞뒤 문맥(TextQuoteSelector)으로 위치를 찾아 <mark> 로 감싼다
// - TTS: 읽는 문장을 표시하고 화면에 보이게 스크롤한다
(function () {
  if (window.__reader) return;
  const R = (window.__reader = {});
  const CONTEXT = 32;

  function root() { return document.querySelector('article') || document.body; }

  // 번역문(.tr)은 원문 위치 계산에서 제외한다
  function textNodes() {
    const out = [];
    const walker = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        const p = n.parentElement;
        return p && p.closest('.tr, script, style') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      },
    });
    let n;
    while ((n = walker.nextNode())) out.push(n);
    return out;
  }

  function index() {
    const nodes = textNodes();
    const map = [];
    let text = '';
    for (const n of nodes) { map.push({ node: n, start: text.length }); text += n.data; }
    return { text, map };
  }

  function offsetOf(idx, container, offset) {
    if (container.nodeType === Node.TEXT_NODE) {
      const e = idx.map.find((m) => m.node === container);
      if (e) return e.start + offset;
    }
    const child = container.childNodes ? container.childNodes[offset] : null;
    for (const m of idx.map) {
      if (child) {
        if (child === m.node || child.contains(m.node) ||
            (child.compareDocumentPosition(m.node) & Node.DOCUMENT_POSITION_FOLLOWING)) return m.start;
      } else if ((container.compareDocumentPosition(m.node) & Node.DOCUMENT_POSITION_FOLLOWING) &&
                 !container.contains(m.node)) {
        return m.start;
      }
    }
    return idx.text.length;
  }

  R.selection = function () {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
    const range = sel.getRangeAt(0);
    const idx = index();
    let start = offsetOf(idx, range.startContainer, range.startOffset);
    let end = offsetOf(idx, range.endContainer, range.endOffset);
    // 앞뒤 공백은 잘라낸다
    while (start < end && /\s/.test(idx.text[start])) start++;
    while (end > start && /\s/.test(idx.text[end - 1])) end--;
    if (end <= start) return null;
    return {
      quote: idx.text.slice(start, end),
      prefix: idx.text.slice(Math.max(0, start - CONTEXT), start),
      suffix: idx.text.slice(end, end + CONTEXT),
    };
  };

  R.clearSelection = function () { window.getSelection().removeAllRanges(); };

  function commonSuffix(a, b) { let i = 0; while (i < a.length && i < b.length && a[a.length - 1 - i] === b[b.length - 1 - i]) i++; return i; }
  function commonPrefix(a, b) { let i = 0; while (i < a.length && i < b.length && a[i] === b[i]) i++; return i; }

  function locate(idx, h) {
    let best = null, bestScore = -1, from = 0;
    while (true) {
      const at = idx.text.indexOf(h.quote, from);
      if (at < 0) break;
      const before = idx.text.slice(Math.max(0, at - CONTEXT), at);
      const after = idx.text.slice(at + h.quote.length, at + h.quote.length + CONTEXT);
      const score = commonSuffix(before, h.prefix || '') + commonPrefix(after, h.suffix || '');
      if (score > bestScore) { bestScore = score; best = at; }
      from = at + 1;
    }
    return best === null ? null : [best, best + h.quote.length];
  }

  function wrap(idx, start, end, h) {
    const segments = [];
    for (const m of idx.map) {
      const s = m.start, e = m.start + m.node.data.length;
      if (e <= start || s >= end) continue;
      segments.push({ node: m.node, from: Math.max(0, start - s), to: Math.min(m.node.data.length, end - s) });
    }
    for (const seg of segments) {
      let node = seg.node;
      if (seg.to < node.data.length) node.splitText(seg.to);
      if (seg.from > 0) node = node.splitText(seg.from);
      if (!node.data.trim()) continue;
      const mark = document.createElement('mark');
      mark.className = 'hl hl-' + h.color + (h.note ? ' has-note' : '');
      mark.dataset.hl = h.id;
      node.parentNode.insertBefore(mark, node);
      mark.appendChild(node);
    }
  }

  function unwrapAll() {
    document.querySelectorAll('mark[data-hl]').forEach((m) => {
      const parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
      parent.normalize();
    });
  }

  // 하이라이트 목록 전체를 다시 그린다. 반환값: 찾지 못한 하이라이트 id 목록
  R.syncHighlights = function (list) {
    unwrapAll();
    const missing = [];
    for (const h of list) {
      const idx = index(); // wrap 할 때마다 텍스트 노드가 바뀌므로 다시 계산
      const range = locate(idx, h);
      if (range) wrap(idx, range[0], range[1], h); else missing.push(h.id);
    }
    return missing;
  };

  R.scrollToHighlight = function (id) {
    const m = document.querySelector('mark[data-hl="' + id + '"]');
    if (m) m.scrollIntoView({ block: 'center' });
  };

  document.addEventListener('click', (e) => {
    const m = e.target.closest && e.target.closest('mark[data-hl]');
    if (m) {
      e.preventDefault();
      window.webkit.messageHandlers.highlight.postMessage(m.dataset.hl);
    }
  }, true);
})();

// ---- TTS: 읽는 문장 표시 (DOM 을 바꾸지 않는 CSS Custom Highlight API 사용) ----
(function () {
  const R = window.__reader;
  if (!R || R.ttsMark) return;
  let cursor = 0;

  function allText() {
    const root = document.querySelector('article') || document.body;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const map = []; let text = ''; let n;
    while ((n = walker.nextNode())) { map.push({ node: n, start: text.length }); text += n.data; }
    return { text, map };
  }

  function point(idx, offset) {
    for (let i = idx.map.length - 1; i >= 0; i--) {
      if (idx.map[i].start <= offset) return [idx.map[i].node, Math.min(offset - idx.map[i].start, idx.map[i].node.data.length)];
    }
    return null;
  }

  // 공백 차이를 무시하고 찾기 위해 공백을 정규식으로 바꾼다
  function find(text, sentence, from) {
    const esc = sentence.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\s+/g, '\\s+');
    const re = new RegExp(esc, 'g');
    re.lastIndex = from;
    let m = re.exec(text);
    if (!m && from > 0) { re.lastIndex = 0; m = re.exec(text); }
    return m ? [m.index, m.index + m[0].length] : null;
  }

  R.ttsReset = function () { cursor = 0; if (window.CSS && CSS.highlights) CSS.highlights.delete('tts'); };

  R.ttsMark = function (sentence) {
    const idx = allText();
    const found = find(idx.text, sentence, cursor);
    if (!found) return false;
    cursor = found[0] + 1;
    const a = point(idx, found[0]), b = point(idx, found[1]);
    if (!a || !b) return false;
    const range = document.createRange();
    range.setStart(a[0], a[1]);
    range.setEnd(b[0], b[1]);
    if (window.CSS && CSS.highlights) CSS.highlights.set('tts', new Highlight(range));
    const rect = range.getBoundingClientRect();
    if (rect.top < 80 || rect.bottom > window.innerHeight - 140) {
      window.scrollBy({ top: rect.top - window.innerHeight * 0.3, behavior: 'smooth' });
    }
    return true;
  };

  // ---- 검색어 표시: 목록에서 검색해 연 글에서 일치하는 곳을 모두 칠한다 ----
  R.findClear = function () { if (window.CSS && CSS.highlights) CSS.highlights.delete('search'); };

  // 반환값: 찾은 개수. scroll 이 true 면 첫 번째 일치로 이동한다.
  R.find = function (term, scroll) {
    R.findClear();
    const needle = (term || '').trim().toLowerCase();
    if (!needle || !(window.CSS && CSS.highlights)) return 0;
    const idx = allText();
    const hay = idx.text.toLowerCase();
    const ranges = [];
    for (let at = hay.indexOf(needle); at !== -1 && ranges.length < 300; at = hay.indexOf(needle, at + needle.length)) {
      const a = point(idx, at), b = point(idx, at + needle.length);
      if (!a || !b) continue;
      const range = document.createRange();
      range.setStart(a[0], a[1]);
      range.setEnd(b[0], b[1]);
      ranges.push(range);
    }
    if (!ranges.length) return 0;
    CSS.highlights.set('search', new Highlight(...ranges));
    if (scroll) {
      const rect = ranges[0].getBoundingClientRect();
      window.scrollBy({ top: rect.top - window.innerHeight * 0.3, behavior: 'smooth' });
    }
    return ranges.length;
  };
})();
