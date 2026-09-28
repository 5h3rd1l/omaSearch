.pragma library

// Default-agent map shared with the overlay. Keep in sync with ask.py.

var PROVIDERS = {
  grok: { id: "grok", name: "Grok", web: "https://grok.com", canAsk: true },
  claude: { id: "claude", name: "Claude", web: "https://claude.ai/new", canAsk: true },
  gemini: { id: "gemini", name: "Gemini", web: "https://gemini.google.com/app", canAsk: true },
  copilot: { id: "copilot", name: "Copilot", web: "https://copilot.microsoft.com", canAsk: true },
  codex: { id: "codex", name: "Codex", web: "https://chatgpt.com", canAsk: true },
  opencode: { id: "opencode", name: "OpenCode", web: "https://opencode.ai", canAsk: true },
  crush: { id: "crush", name: "Crush", web: "https://crush.xyz", canAsk: true },
  pi: { id: "pi", name: "Pi", web: "", canAsk: true },
  omp: { id: "omp", name: "Oh My Pi", web: "", canAsk: true }
}

var AGENT_RE = /^[a-z0-9][a-z0-9._-]{0,31}$/
var MAX_FIELD = 2000

function clip(value, limit) {
  // Bound a string for display or IPC; drop C0/C1 controls.
  var text = String(value || "")
  var out = ""
  var max = limit || MAX_FIELD
  for (var i = 0; i < text.length && out.length < max; i++) {
    var code = text.charCodeAt(i)
    if (code < 32 || (code >= 127 && code <= 159)) continue
    out += text.charAt(i)
  }
  return out
}

function clipText(value, limit) {
  // Bound an answer like clip(), but keep line breaks and indentation so
  // paragraphs, lists and code survive.
  return String(value || "")
    .replace(/\r\n?/g, "\n")
    .replace(/\t/g, "    ")
    .replace(/[\x00-\x09\x0b-\x1f\x7f-\x9f\ue000\ue001]/g, "")
    .slice(0, limit || MAX_FIELD)
}

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function inlineHtml(text, codeColor, dimColor) {
  // Markdown inline spans → StyledText. The text is escaped first, so only the
  // tags built here reach the Text item. Code spans and links are set aside as
  // placeholders so their contents are not formatted.
  var held = []
  function hold(html) {
    held.push(html)
    return "\ue000" + (held.length - 1) + "\ue001"
  }
  var s = String(text)
    .replace(/`([^`\n]+)`/g, function(m, code) {
      return hold("<font color=\"" + codeColor + "\">" + escapeHtml(code) + "</font>")
    })
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, function(m, label, url) {
      return hold(link(url, label, codeColor))
    })
    .replace(/https?:\/\/[^\s<>"'`\]]+/g, function(url) {
      // Bare URL; trailing punctuation stays outside the link.
      var tail = /[.,;:!?)]+$/.exec(url)
      var bare = tail ? url.slice(0, url.length - tail[0].length) : url
      return hold(link(bare, bare, codeColor)) + (tail ? tail[0] : "")
    })
  s = escapeHtml(s)
    .replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, "<b>$1</b>")
    .replace(/(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/g, "$1<b>$2</b>")
    .replace(/(^|[^*\w])\*(?=[^\s*])([^*\n]*?[^\s*])\*(?![*\w])/g, "$1<i>$2</i>")
    .replace(/(^|[^\w])_(?=[^\s_])([^_\n]*?[^\s_])_(?!\w)/g, "$1<i>$2</i>")
    .replace(/~~(?=\S)([\s\S]*?\S)~~/g, "<s>$1</s>")
    .replace(/\n/g, "<br>")
  return s.replace(/\ue000(\d+)\ue001/g, function(m, i) { return held[Number(i)] })
}

function link(url, label, color) {
  // A clickable link (the overlay opens http(s) links in the default browser).
  return '<a href="' + escapeHtml(url) + '" style="color:' + color + '; text-decoration:underline;">'
    + escapeHtml(label) + "</a>"
}

function tableText(rows) {
  // A pipe table as aligned monospace text (the overlay font is monospace).
  var cells = []
  var widths = []
  for (var r = 0; r < rows.length; r++) {
    var line = rows[r].replace(/^\s*\|/, "").replace(/\|\s*$/, "")
    if (/^\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*$/.test(line)) continue
    var row = line.split("|").map(function(c) {
      return c.replace(/\*\*|__|`/g, "").replace(/^\s+|\s+$/g, "")
    })
    for (var c = 0; c < row.length; c++) widths[c] = Math.max(widths[c] || 0, row[c].length)
    cells.push(row)
  }
  var out = []
  for (var i = 0; i < cells.length; i++) {
    var padded = []
    for (var j = 0; j < cells[i].length; j++)
      padded.push(j === cells[i].length - 1 ? cells[i][j] : cells[i][j] + " ".repeat(widths[j] - cells[i][j].length))
    out.push(padded.join("  "))
    if (i === 0 && cells.length > 1) {
      var rule = []
      for (var k = 0; k < widths.length; k++) rule.push("─".repeat(widths[k]))
      out.push(rule.join("  "))
    }
  }
  return out.join("\n")
}

function parseMarkdown(text, codeColor, dimColor) {
  // Split an answer into blocks the overlay lays out one by one:
  //   p / h / li / quote → { html }   code / table → { text }   hr
  // `gap` is the space above a block, mirroring the answer's own spacing:
  // 0 first block, 1 a plain line break, 2 a blank line before it.
  // An unclosed ``` fence (still streaming) runs to the end as code.
  var lines = clipText(text, 20000).split("\n")
  var blocks = []
  var open = null   // p / li / quote collecting lines, or a table
  var fence = null
  var bullets = ["•", "◦", "▪", "◦"]
  var indents = []  // indent of each open list level, for nesting depth
  var sawBlank = false

  function takeBlank() {
    var blank = sawBlank
    sawBlank = false
    return blank
  }
  function add(block, blank) {
    block.gap = !blocks.length ? 0 : blank ? 2 : 1
    blocks.push(block)
  }
  function flush() {
    if (!open) return
    if (open.kind === "table") add({ kind: "table", text: tableText(open.lines) }, open.blank)
    else add({ kind: open.kind, level: open.level || 0, depth: open.depth || 0, marker: open.marker || "",
               ordered: !!open.ordered, html: inlineHtml(open.lines.join("\n"), codeColor, dimColor) }, open.blank)
    open = null
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var m

    if (fence) {
      m = /^\s*(`{3,}|~{3,})\s*$/.exec(line)
      if (m && m[1].charAt(0) === fence.marker.charAt(0) && m[1].length >= fence.marker.length) {
        add({ kind: "code", text: fence.lines.join("\n"), lang: fence.lang }, fence.blank)
        fence = null
      } else {
        var lead = /^ */.exec(line)[0].length
        fence.lines.push(line.slice(Math.min(lead, fence.indent)))
      }
      continue
    }
    if ((m = /^(\s*)(`{3,}|~{3,})\s*([\w+#.-]*)\s*$/.exec(line))) {
      flush()
      fence = { indent: m[1].length, marker: m[2], lang: m[3].toLowerCase(), lines: [], blank: takeBlank() }
      indents = []
      continue
    }
    if (!/\S/.test(line)) {
      flush()
      sawBlank = true
      continue
    }
    if (/^\s*\|.*\|\s*$/.test(line)) {
      if (!open || open.kind !== "table") {
        flush()
        open = { kind: "table", lines: [], blank: takeBlank() }
        indents = []
      }
      open.lines.push(line)
      continue
    }
    if ((m = /^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/.exec(line))) {
      flush()
      indents = []
      add({ kind: "h", level: m[1].length, depth: 0, marker: "", ordered: false,
            html: inlineHtml(m[2], codeColor, dimColor) }, takeBlank())
      continue
    }
    if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) {
      flush()
      indents = []
      add({ kind: "hr" }, takeBlank())
      continue
    }
    if ((m = /^(\s*)([-*+]|\d{1,3}[.)])\s+(?:\[([ xX])\]\s+)?(.*)$/.exec(line))) {
      flush()
      while (indents.length && indents[indents.length - 1] > m[1].length) indents.pop()
      if (!indents.length || indents[indents.length - 1] < m[1].length) indents.push(m[1].length)
      var depth = Math.min(3, indents.length - 1)
      var ordered = /\d/.test(m[2])
      var marker = m[3] !== undefined ? (m[3] === " " ? "☐" : "☑")
        : ordered ? m[2].replace(")", ".") : bullets[depth]
      open = { kind: "li", depth: depth, marker: marker, ordered: ordered, lines: [m[4]], blank: takeBlank() }
      continue
    }
    if ((m = /^\s*>\s?(.*)$/.exec(line))) {
      if (!open || open.kind !== "quote") {
        flush()
        open = { kind: "quote", lines: [], blank: takeBlank() }
        indents = []
      }
      open.lines.push(m[1])
      continue
    }
    // Plain text continues the open paragraph / list item / quote, keeping
    // its line breaks; otherwise it starts a paragraph.
    if (open && open.kind !== "table") {
      open.lines.push(line.replace(/^\s+/, ""))
    } else {
      flush()
      open = { kind: "p", lines: [line.replace(/^\s+/, "")], blank: takeBlank() }
      indents = []
    }
  }
  flush()
  if (fence) add({ kind: "code", text: fence.lines.join("\n"), lang: fence.lang }, fence.blank)

  // Numbered markers in one list share a width so the text lines up.
  // `slot` is that width in characters, including the space after it.
  for (var b = 0; b < blocks.length; b++) {
    if (blocks[b].kind !== "li") continue
    var end = b
    var widest = {}
    while (end < blocks.length && blocks[end].kind === "li") {
      var key = blocks[end].depth + (blocks[end].ordered ? "#" : "")
      widest[key] = Math.max(widest[key] || 0, blocks[end].marker.length)
      end++
    }
    // `lead` is where the marker starts: under the parent item's text.
    var textAt = []
    for (var k = b; k < end; k++) {
      var item = blocks[k]
      item.slot = widest[item.depth + (item.ordered ? "#" : "")] + 1
      item.lead = item.depth > 0 ? (textAt[item.depth - 1] || 0) : 0
      textAt[item.depth] = item.lead + item.slot
    }
    b = end - 1
  }
  return blocks
}

function proseHtml(block, st, top) {
  // One prose block as a rich-text paragraph. List items hang their marker in
  // a negative indent so wrapped lines line up under the text.
  var base = "margin-top:" + top + "px; margin-bottom:0px; "
  var tall = "line-height:" + st.leadingPct + "%; "
  if (block.kind === "h")
    return '<p style="' + base + 'font-weight:600; font-size:' + (block.level <= 2 ? st.titlePx : st.bodyPx) + 'px;">'
      + block.html + "</p>"
  if (block.kind === "li") {
    var pad = Math.round(block.slot * st.charWidth)
    var lead = Math.round((block.lead || 0) * st.charWidth)
    var marker = escapeHtml(block.marker) + "&nbsp;".repeat(Math.max(1, block.slot - block.marker.length))
    return '<p style="' + base + tall + "margin-left:" + (lead + pad) + "px; text-indent:-" + pad + 'px;">'
      + '<font color="' + st.note + '">' + marker + "</font>" + block.html + "</p>"
  }
  if (block.kind === "quote")
    return '<p style="' + base + tall + "margin-left:" + st.quotePx + "px; color:" + st.note + ';">' + block.html + "</p>"
  return '<p style="' + base + tall + '">' + block.html + "</p>"
}

function answerSegments(text, st) {
  // What the overlay lays out for an answer: runs of prose, each one
  // selectable rich-text document (so a selection can span paragraphs and
  // lists), then code / table boxes and rules between them. `gap` is the
  // space above a segment as in parseMarkdown; `tail` is true when its last
  // line carries the tall line height (spare leading underneath).
  // st: { code, dim, note: colours; charWidth, blankPx, bodyPx, titlePx,
  //       quotePx: pixels; leadingPct }
  var blocks = parseMarkdown(text, st.code, st.dim)
  var segments = []
  var prose = null
  for (var i = 0; i < blocks.length; i++) {
    var b = blocks[i]
    if (b.kind === "code" || b.kind === "table" || b.kind === "hr") {
      prose = null
      segments.push({ kind: b.kind === "hr" ? "hr" : "code", text: b.text || "", html: "", gap: b.gap, tail: false,
                      lang: b.kind === "table" ? "table" : (b.lang || "") })
      continue
    }
    if (!prose) {
      prose = { kind: "prose", text: "", html: "", gap: b.gap, tail: false }
      segments.push(prose)
      prose.html += proseHtml(b, st, 0)
    } else {
      prose.html += proseHtml(b, st, b.gap === 2 ? st.blankPx : 0)
    }
    prose.tail = b.kind !== "h"
  }
  return segments
}

var SESSION_RE = /^[A-Za-z0-9_-]{1,80}$/
var ROW_KINDS = { you: true, text: true, tool: true, error: true }

function trimSteps(json, limit) {
  // Tool steps as saved in recent chats: command / output clipped to `limit`.
  var steps
  try { steps = JSON.parse(json || "[]") } catch (e) { return "[]" }
  if (!Array.isArray(steps)) return "[]"
  var out = []
  for (var i = 0; i < steps.length && i < 50; i++) {
    var s = steps[i] || {}
    out.push({ id: clip(s.id, 80), name: clip(s.name, 80) || "Tool", description: clip(s.description, 200),
               input: clipText(s.input, limit), output: clipText(s.output, limit),
               error: s.error === true, done: true })
  }
  return JSON.stringify(out)
}

function parseHistory(text, maxChats) {
  // Recent chats from history.json, newest first. Every field is checked and
  // bounded, so a hand-edited or damaged file can't break the overlay.
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return [] }
  var chats = data && Array.isArray(data.chats) ? data.chats : []
  var out = []
  for (var i = 0; i < chats.length && out.length < maxChats; i++) {
    var c = chats[i]
    if (!c || !SESSION_RE.test(String(c.id || "")) || !Array.isArray(c.turns) || !Array.isArray(c.rows)) continue
    var turns = []
    for (var t = 0; t < c.turns.length && t < 200; t++) {
      var turn = c.turns[t] || {}
      turns.push({ q: clipText(turn.q, 2000), a: clipText(turn.a, 6000), error: clip(turn.error, 240) })
    }
    var rows = []
    for (var r = 0; r < c.rows.length && r < 400; r++) {
      var row = c.rows[r] || {}
      if (!ROW_KINDS[row.kind]) continue
      rows.push({ kind: row.kind, text: clipText(row.text, 6000), count: Math.max(1, Math.min(999, Number(row.count) || 1)),
                  steps: row.kind === "tool" ? trimSteps(row.steps, 1500) : "[]" })
    }
    var sessions = {}
    for (var agent in (c.sessions || {}))
      if (normalizeAgent(agent) === agent && SESSION_RE.test(String(c.sessions[agent]))) sessions[agent] = String(c.sessions[agent])
    if (!turns.length) continue
    out.push({ id: String(c.id), title: clip(c.title, 120) || clip(turns[0].q, 120), titled: c.titled === true,
               agent: normalizeAgent(c.agent),
               updated: Number(c.updated) || 0, sessions: sessions, turns: turns, rows: rows })
  }
  return out
}

function parseIds(text, key) {
  // An id list from history.json: "hidden" Claude sessions or "pinned" chats.
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return [] }
  var list = data && Array.isArray(data[key]) ? data[key] : []
  var out = []
  for (var i = 0; i < list.length && out.length < 500; i++)
    if (SESSION_RE.test(String(list[i]))) out.push(String(list[i]))
  return out
}

function parseHidden(text) {
  return parseIds(text, "hidden")
}

function parsePrompts(text) {
  // Questions you asked, oldest first, for Ctrl+Up / Ctrl+Down.
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return [] }
  var list = data && Array.isArray(data.prompts) ? data.prompts : []
  var out = []
  for (var i = Math.max(0, list.length - 100); i < list.length; i++) {
    var p = clip(list[i], 2000)
    if (p) out.push(p)
  }
  return out
}

function filterRecent(chats, query) {
  // Recent chats whose title has every typed word (case-insensitive).
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function(w) { return w })
  if (!words.length) return chats
  return chats.filter(function(c) {
    var title = String(c.title || "").toLowerCase()
    for (var i = 0; i < words.length; i++) if (title.indexOf(words[i]) === -1) return false
    return true
  })
}

function mergeRecent(history, claude, hidden, pinned, max) {
  // One recent list, newest first: omaSeek's saved chats plus its Claude chats
  // read from Claude's own session files (so older chats, and ones continued
  // in the terminal, show up too). A session that is also a saved chat shows
  // once; when Claude's copy is newer it is reopened from there. Hidden
  // sessions are left out.
  var hide = {}
  for (var h = 0; h < hidden.length; h++) hide[hidden[h]] = true
  var saved = {}
  var out = []
  for (var i = 0; i < history.length; i++) {
    var e = history[i]
    var sid = (e.sessions && e.sessions.claude) || ""
    if (sid && hide[sid]) continue
    var item = { kind: "saved", id: e.id, session: sid, title: e.title, agent: e.agent, updated: e.updated }
    if (sid) saved[sid] = item
    out.push(item)
  }
  for (var j = 0; j < claude.length; j++) {
    var c = claude[j] || {}
    var session = String(c.session || "")
    if (!SESSION_RE.test(session) || hide[session]) continue
    var twin = saved[session]
    if (twin) {
      if (Number(c.updated) > twin.updated + 5000) {
        twin.kind = "claude"
        twin.updated = Number(c.updated)
      }
      continue
    }
    out.push({ kind: "claude", id: "c_" + session, session: session, title: clip(c.title, 120) || "Chat",
               agent: "claude", updated: Number(c.updated) || 0 })
  }
  // Pinned chats first, then newest first.
  var pin = {}
  for (var p = 0; p < pinned.length; p++) pin[pinned[p]] = true
  for (var k = 0; k < out.length; k++) out[k].pinned = pin[out[k].id] === true
  out.sort(function(a, b) {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1
    return b.updated - a.updated
  })
  return out.slice(0, max)
}

function timeAgo(ms, now) {
  // "now", "5m", "3h", "2d", then a short date.
  var s = Math.max(0, Math.round((now - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return Math.floor(s / 60) + "m"
  if (s < 86400) return Math.floor(s / 3600) + "h"
  if (s < 7 * 86400) return Math.floor(s / 86400) + "d"
  var d = new Date(ms)
  return ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()] + " " + d.getDate()
}

var SH_WORDS = "if then else elif fi for in do done while until case esac function return select local export"
var PY_WORDS = "def class import from return if elif else for while in not and or is None True False with as "
  + "try except finally raise lambda yield pass break continue global nonlocal async await self"
var C_WORDS = "function const let var return if else for while do switch case break continue new class extends "
  + "import export from default true false null undefined this typeof instanceof async await try catch finally "
  + "throw int char void struct static public private protected fn mut impl use pub match package func type "
  + "interface enum bool string property readonly signal required component"
var CONF_WORDS = "true false yes no on off null"
var KEYWORDS = {}
function wordSet(list) {
  var set = {}
  list.split(" ").forEach(function(w) { set[w] = true })
  return set
}
KEYWORDS.sh = wordSet(SH_WORDS)
KEYWORDS.py = wordSet(PY_WORDS)
KEYWORDS.c = wordSet(C_WORDS)
KEYWORDS.conf = wordSet(CONF_WORDS)
// Words that come before the real command: `sudo pacman ...` colours pacman too.
var SH_PREFIX = wordSet("sudo doas env time exec nohup command builtin xargs")

function codeKind(lang) {
  var l = String(lang || "")
  if (/^(sh|bash|zsh|fish|shell|console|terminal|shellsession|)$/.test(l)) return "sh"
  if (/^(py|python|python3)$/.test(l)) return "py"
  if (/^(js|javascript|ts|typescript|jsx|tsx|json|jsonc|qml|c|h|cpp|c\+\+|cc|hpp|java|kotlin|go|rust|rs|css|scss|swift|cs|csharp|php|dart|zig|lua)$/.test(l)) return "c"
  if (/^(yaml|yml|toml|ini|conf|cfg|properties|env|dotenv|hyprlang|nix)$/.test(l)) return "conf"
  return "plain"
}

function highlightCode(code, lang, pal) {
  // Code block as rich text with theme colours: keywords, strings, numbers,
  // comments; for shell also commands, flags and $variables. Whitespace kept.
  var kind = codeKind(lang)
  var text = String(code || "")
  if (kind === "plain") return '<pre style="white-space:pre-wrap; margin:0px;">' + escapeHtml(text) + "</pre>"
  var words = KEYWORDS[kind]
  var re = kind === "sh"
    ? /(#[^\n]*)|("(?:\\.|[^"\\])*"|'[^']*')|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!$-])|(--?[A-Za-z][\w-]*)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_./~][\w./~+-]*)/g
    : kind === "py"
    ? /(#[^\n]*)|("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|((?!))|((?!))|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][\w]*)/g
    : kind === "c"
    ? /(\/\/[^\n]*|\/\*[\s\S]*?\*\/|--[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|((?!))|((?!))|(\b\d+(?:\.\d+)?\b)|([A-Za-z_$][\w$]*)/g
    : /(#[^\n]*|(?:^|\n)\s*;[^\n]*)|("(?:\\.|[^"\\\n])*"|'[^'\n]*')|((?!))|((?!))|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][\w.-]*)/g
  function paint(color, t, italic) {
    var body = escapeHtml(t)
    if (italic) body = "<i>" + body + "</i>"
    return color ? '<font color="' + color + '">' + body + "</font>" : body
  }
  var out = ""
  var at = 0
  var atCmd = true        // shell: the next word is a command
  var m
  while ((m = re.exec(text)) !== null) {
    if (m[0] === "") { re.lastIndex++; continue }
    var gap = text.slice(at, m.index)
    out += escapeHtml(gap)
    if (/[|;&(\n]/.test(gap)) atCmd = true
    var t = m[0]
    if (m[1]) out += paint(pal.com, t, true)
    else if (m[2]) out += paint(pal.str, t)
    else if (m[3]) out += paint(pal.vari, t)
    else if (m[4]) out += paint(pal.flag, t)
    else if (m[5]) out += paint(pal.num, t)
    else if (words[t]) {
      out += paint(pal.kw, t)
      // After these a shell command follows: `do echo`, `if grep ...`.
      if (kind === "sh") atCmd = /^(do|then|else|elif|if|while|until)$/.test(t)
      at = re.lastIndex
      continue
    }
    else if (kind === "sh" && atCmd) {
      out += paint(pal.cmd, t)
      if (!SH_PREFIX[t]) atCmd = false
      at = re.lastIndex
      continue
    } else if (kind === "conf" && /^\s*[:=]/.test(text.slice(re.lastIndex))) out += paint(pal.cmd, t)
    else out += escapeHtml(t)
    if (kind === "sh") atCmd = false
    at = re.lastIndex
  }
  out += escapeHtml(text.slice(at))
  return '<pre style="white-space:pre-wrap; margin:0px;">' + out + "</pre>"
}

function plainSelection(text) {
  // TextEdit.selectedText marks paragraph / line breaks with U+2029 / U+2028.
  return String(text || "").replace(/[\u2028\u2029]/g, "\n").replace(/\u00a0/g, " ")
}

function normalizeAgent(raw) {
  // Map `omarchy default agent` aliases to a canonical, allowlisted id.
  var id = String(raw || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (id === "claude-code") id = "claude"
  else if (id === "gemini-cli") id = "gemini"
  else if (id === "github-copilot") id = "copilot"
  else if (id === "open-code") id = "opencode"
  else if (id === "oh-my-pi") id = "omp"
  if (!id || id === "." || id === ".." || id.indexOf("/") !== -1 || !AGENT_RE.test(id))
    return ""
  return PROVIDERS[id] ? id : ""
}

function providerFor(raw) {
  // Look up display name, web chat URL, and overlay-ask support.
  var id = normalizeAgent(raw)
  var known = PROVIDERS[id]
  if (known) return known
  return { id: "", name: "AI", web: "", canAsk: false }
}

function placeholderFor(provider) {
  // Input placeholder: "Ask Grok", or "Ask AI" if no default agent is set.
  return "Ask " + (provider && provider.name ? provider.name : "AI")
}

function parseAskOutput(raw) {
  // Parse a small JSON object from ask.py; reject oversized or untyped fields.
  var text = clip(raw, 65536)
  if (!text) return { ok: false, error: "No response from ask helper." }

  var start = text.indexOf("{")
  var end = text.lastIndexOf("}")
  if (start === -1 || end === -1 || end <= start)
    return { ok: false, error: clip(text, 240) }

  var data
  try {
    data = JSON.parse(text.slice(start, end + 1))
  } catch (e) {
    return { ok: false, error: "Could not parse helper output." }
  }
  if (!data || typeof data !== "object") return { ok: false, error: "Invalid helper output." }

  return {
    ok: data.ok === true,
    agent: normalizeAgent(data.agent),
    name: clip(data.name, 40),
    web: clip(data.web, 200),
    canAsk: data.canAsk === true,
    summary: clipText(data.summary, 6000),
    error: clip(data.error, 240),
    code: clip(data.code, 40),
    session: /^[A-Za-z0-9_-]{1,80}$/.test(String(data.session || "")) ? String(data.session) : ""
  }
}
