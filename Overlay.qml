import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "AskModel.js" as AskModel

// omaSearch overlay. IPC: open / close / toggle / dismiss.
// Enter → ask.py (short on-screen answer). Ctrl+Enter → Google search in the
// default browser. The key hints and chat actions sit in a bar under the pill.
// After an answer, typing again replies in the same chat: Claude, Codex and
// OpenCode continue their real CLI session (other agents / a switched agent get
// the earlier turns as context). "Open in terminal" resumes that session in the
// agent's own TUI.
// Look and motion follow the Omagent plugin: frosted pill + chat card, spring
// in, drag to move (remembered). The chat survives closing (Esc) until New ^N;
// an answer that lands while hidden raises a notification.
// Claude answers stream from a warm process (ask.py --serve) that starts when
// omaSearch opens and serves the whole chat, so replies begin at once like the
// terminal. Other agents run one ask.py --ask per message.
// Click the agent logo to pick from the installed agents; the pick is saved by
// ask.py --select and used until it is changed again. The model label left of
// the hints opens the same kind of list for the current agent's models
// (saved per agent by ask.py --select-model).
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string promptText: ""
  property string summary: ""
  property string errorText: ""
  property string status: "idle"
  property string agentId: ""
  property string askPrompt: ""
  property string askBuf: ""
  property string askErrBuf: ""
  property string copyPayload: ""
  property string browserAgent: ""
  property string browserPayload: ""
  property var provider: AskModel.providerFor("")
  property var agents: []
  property string listBuf: ""
  property string pendingSelect: ""
  property bool pickerOpen: false
  property var models: []
  property string modelId: ""
  property string modelsBuf: ""
  property string modelsAgent: ""
  property string pendingModelAgent: ""
  property string pendingModel: ""
  property bool modelPickerOpen: false
  // Chat so far: [{ q, a, error }]; the last turn is pending while asking.
  property var turns: []
  property string askPayload: ""
  // Session id per agent for this chat, from ask.py; resumed on follow-ups.
  property var chatSessions: ({})
  property string askSession: ""
  readonly property string currentSession: root.chatSessions[root.agentId] || ""
  readonly property int maxChatChars: 10000
  property int dragX: 0
  property int dragY: 0
  property bool followTail: true
  // Collapses every expanded tool row (a click on empty space).
  signal collapseTools()

  // Chat text you can select with the mouse; Ctrl+C copies the selection. It
  // never takes keyboard focus, so typing stays in the prompt.
  component ChatText: TextEdit {
    id: chatText
    // A click (not a drag, not on a link). The text takes the press itself,
    // so handlers on the row / list never see clicks on it; a double click
    // arrives as two.
    signal clicked()

    readOnly: true
    selectByMouse: true
    activeFocusOnPress: false
    persistentSelection: true
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.Wrap
    selectionColor: Style.selectionFill
    selectedTextColor: Color.menu.text

    TapHandler {
      onTapped: function(eventPoint) {
        if (!chatText.linkAt(eventPoint.position.x, eventPoint.position.y)) chatText.clicked()
      }
    }

    HoverHandler {
      cursorShape: chatText.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor
    }
  }

  // Liquid-glass finish for a rounded surface (the surface itself is a
  // translucent tint the compositor blurs behind): a soft sheen across the
  // top, a faint rim all round, and a brighter rim that catches the light at
  // the top edge, fades down the sides and comes back faintly at the bottom.
  component GlassSheen: Item {
    id: glass

    property real radius: 0
    property real strength: 1.0

    anchors.fill: parent

    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.075 * glass.strength) }
        GradientStop { position: 0.42; color: Qt.rgba(1, 1, 1, 0.0) }
      }
    }

    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.08 * glass.strength)
    }

    Rectangle {
      anchors.fill: parent
      radius: glass.radius
      color: "transparent"
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, Math.min(0.9, 0.4 * glass.strength))
      layer.enabled: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: rimMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }
    }

    Item {
      id: rimMask
      anchors.fill: parent
      visible: false
      layer.enabled: true

      Rectangle {
        anchors.fill: parent
        gradient: Gradient {
          GradientStop { position: 0.0; color: "white" }
          GradientStop { position: 0.45; color: "transparent" }
          GradientStop { position: 0.8; color: "transparent" }
          GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.35) }
        }
      }
    }
  }

  // A menu row with a switch (the model menu's Detailed / Safe settings).
  component SettingRow: Rectangle {
    id: setting

    property string label: ""
    property string hint: ""
    property bool checked: false
    signal toggled()

    height: Style.space(36)
    radius: height / 2
    color: settingArea.containsMouse ? Color.menu.selectedBackground : "transparent"

    Behavior on color {
      ColorAnimation { duration: 100 }
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      text: setting.label
      color: Color.menu.text
      opacity: 0.9
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.right: track.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: setting.hint
      color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.5)
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: track
      anchors.right: parent.right
      anchors.rightMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(28)
      height: Style.space(16)
      radius: height / 2
      color: setting.checked ? Color.accent : Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.18)

      Behavior on color {
        ColorAnimation { duration: 120 }
      }

      Rectangle {
        width: parent.height - Style.space(4)
        height: width
        radius: width / 2
        y: Style.space(2)
        x: setting.checked ? parent.width - width - Style.space(2) : Style.space(2)
        color: setting.checked ? Color.menu.background : Color.menu.text

        Behavior on x {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
      }
    }

    MouseArea {
      id: settingArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: setting.toggled()
    }
  }

  property Item selectionOwner: null   // the chat text holding the selection
  property Item pendingCollapse: null  // tool row a click on its details will close
  property double selectionClearedAt: 0
  property string pendingCopy: ""
  property bool copied: false
  property double askStartedAt: 0
  property int elapsedMs: 0
  readonly property string positionPath: Quickshell.env("HOME") + "/.local/state/omasearch/position.json"
  // Recent chats, listed above the pill while no chat is open. Saved chats
  // live in history.json (the folder is private to you, 0700); omaSearch's Claude
  // chats are also read from Claude's own session files.
  readonly property string historyPath: Quickshell.env("HOME") + "/.local/state/omasearch/history.json"
  readonly property int maxHistory: 25
  property var history: []      // newest first: { id, title, agent, updated, sessions, turns, rows }
  property string chatId: ""    // this chat's entry in `history`
  property var claudeRecent: [] // ask.py --recent-claude: { session, title, updated }
  property var hiddenSessions: [] // Claude sessions taken off the recent list
  property var pinnedIds: []    // pinned chats, shown first
  readonly property var recentChats: AskModel.mergeRecent(root.history, root.claudeRecent,
                                                          root.hiddenSessions, root.pinnedIds, root.maxHistory)
  // Typing (while no chat is open) filters the list; Up / Down pick one and
  // Enter opens it. -1: nothing picked, Enter asks as usual.
  readonly property var recentShown: root.turns.length ? root.recentChats
    : AskModel.filterRecent(root.recentChats, root.promptText)
  property int recentIndex: -1
  property bool clearArmed: false
  // A short title for this chat, made after its first answer (ask.py --title).
  property string chatTitle: ""
  property string titleFor: ""
  property string titleBuf: ""
  property string titlePayload: ""
  // Your earlier questions for Ctrl+Up / Ctrl+Down (oldest first).
  property var promptHistory: []
  property int promptIndex: -1
  property string promptDraft: ""
  property double recentNow: 0
  property string recentBuf: ""
  property string loadSession: "" // Claude chat being reopened (ask.py --load-claude)
  property string loadId: ""
  property string loadBuf: ""
  readonly property bool menuOpen: root.pickerOpen || root.modelPickerOpen || root.helpOpen
  // Ctrl+H: every shortcut and mouse action, in one panel.
  property bool helpOpen: false
  // Ctrl+I: a temporary chat. Nothing about it is kept: no recent-chats entry,
  // no title, no question history, and Claude / Codex save no session.
  property bool tempChat: false
  // A short confirmation that pops up over the pill when a shortcut (or a
  // switch, a copy...) does something; StyledText, so words can be tinted.
  property string toastText: ""
  property bool toastShown: false
  readonly property string agentName: root.provider && root.provider.name ? root.provider.name : "the agent"
  readonly property var helpSections: [
    { title: "Chat", items: [
      ["Enter", "Ask " + root.agentName],
      ["Shift+Enter", "New line"],
      ["Ctrl+Enter", "Search Google in your default browser"],
      ["Ctrl+\u2191 / Ctrl+\u2193", "Bring back earlier questions"],
      ["Ctrl+C", "Stop the answer (copies instead when text is selected)"],
      ["Ctrl+N", "New chat"],
      ["Ctrl+I", "Temporary chat: nothing is saved, and it stays out of recent chats"],
      ["Ctrl+E", "Continue this chat in the terminal"],
      ["Page Up / Down", "Scroll the chat"],
      ["Esc", "Close a menu, then omaSearch (the chat stays until New)"]
    ] },
    { title: "Images and clipboard", items: [
      ["Ctrl+V", "Paste text, or attach a copied image (Claude, max 5 MB)"],
      ["Super+Ctrl+V", "Pick an older image or text from clipboard history"]
    ] },
    { title: "Answers", items: [
      ["Ctrl+D", "Short or detailed answers"],
      ["Select text", "Copies it"],
      ["Click", "A message copies it; a code block copies that block"],
      ["Ctrl+Y", "Copy the last answer"],
      ["Tool row", "Click to see each command and its output"],
      ["Links", "Open in your default browser"]
    ] },
    { title: "Recent chats", items: [
      ["Type", "Filter the list (while no chat is open)"],
      ["\u2191 / \u2193, Enter", "Open a recent chat"],
      ["Hover", "Pin one to the top, or \u00d7 to take it off the list"]
    ] },
    { title: "Model menu (click the model name)", items: [
      ["Models", "Pick the model for this agent"],
      ["Safe mode", "Claude asks before running commands; a red shield means it's off"],
      ["Logo", "Click the agent logo to switch agents"]
    ] }
  ]

  // Answer length and safe mode (Claude asks before running commands),
  // remembered in settings.json. Safe mode is on unless you turn it off.
  readonly property string settingsPath: Quickshell.env("HOME") + "/.local/state/omasearch/settings.json"
  property bool detailed: false
  property bool safeMode: true
  readonly property var modeArgs: (root.detailed ? ["--detailed"] : []).concat(root.safeMode ? ["--safe"] : [])
    .concat(root.tempChat ? ["--temp"] : [])
  property int pendingApprovals: 0

  // An image for the next message (pasted with Ctrl+V; Claude only). It lives
  // in a private cache folder and is deleted once sent.
  readonly property string shotsDir: Quickshell.env("HOME") + "/.cache/omasearch/shots"
  property string attachImage: ""
  property string pasteBuf: ""

  // Code colours from the theme's terminal palette (colors.toml); anything
  // missing falls back to the accent / text colours.
  readonly property string themeColorsPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
  property var themePalette: ({})
  readonly property var codePalette: ({
    kw: root.themePalette.magenta || String(Color.accent),
    str: root.themePalette.green || String(root.note),
    num: root.themePalette.yellow || String(Color.accent),
    com: String(root.subtle),
    cmd: root.themePalette.blue || String(Color.accent),
    flag: root.themePalette.cyan || String(root.note),
    vari: root.themePalette.yellow || String(Color.accent)
  })
  // Warm Claude (ask.py --serve) for this chat.
  readonly property bool warmAgent: root.agentId === "claude"
  property bool serveStarted: false
  property bool serveUsed: false      // the process already holds this chat
  property bool serveRestart: false   // start it again once it has exited
  property string servePending: ""    // message waiting for the process to start
  property bool streaming: false      // the running answer comes from serveProc
  property string streamText: ""
  property int answerRow: -1          // card row the streamed answer grows in
  property bool toolActive: false     // the agent ran a command this turn
  readonly property string lastAnswer: {
    for (var i = root.turns.length - 1; i >= 0; i--)
      if (root.turns[i].a) return root.turns[i].a
    return ""
  }
  readonly property string chatState: {
    if (root.asking) return "asking"
    if (!root.turns.length) return ""
    var last = root.turns[root.turns.length - 1]
    if (last.error === "Stopped") return "stopped"
    return last.error ? "failed" : "done"
  }
  // "opencode/big-pickle" → "big-pickle" for the pill; the menu shows it all.
  readonly property string modelShort: root.modelName.indexOf("/") !== -1
    ? root.modelName.slice(root.modelName.lastIndexOf("/") + 1) : root.modelName
  readonly property string modelName: {
    for (var i = 0; i < root.models.length; i++)
      if (root.models[i].id === root.modelId) return root.models[i].name
    return root.modelId || "Default"
  }

  property color background: Color.menu.background
  // Secondary text from the menu text colour, not Color.muted: some themes set
  // muted close to the menu background, which made these labels unreadable.
  readonly property color subtle: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.6)
  readonly property color note: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.78)
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  readonly property int logoSize: Math.max(Style.space(22), Style.font.heading)
  readonly property string pluginDir: (manifest && manifest.__sourceDir)
    ? String(manifest.__sourceDir)
    : (Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.5h3rd1l.omasearch")
  readonly property string askScript: pluginDir + "/ask.py"
  readonly property string agentFilePath: Quickshell.env("HOME") + "/.config/omarchy/defaults/agent"
  readonly property int maxPrompt: 2000
  readonly property int maxAskBytes: 32768
  readonly property bool asking: status === "asking"
  readonly property bool hasAnswer: status === "done" && summary !== ""
  readonly property bool hasError: status === "error" && errorText !== ""
  readonly property bool showBody: turns.length > 0
  readonly property string placeholder: AskModel.placeholderFor(provider)

  function colorChannelLuminance(value) {
    // sRGB channel to linear luminance component.
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    // Relative luminance of a Qt color, used to pick light vs dark logos.
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  function logoCandidates(agent) {
    // SVG paths for an allowlisted agent id only (default: the current agent).
    var id = AskModel.normalizeAgent(agent !== undefined ? agent : (root.provider && root.provider.id ? root.provider.id : ""))
    if (!id || !AskModel.PROVIDERS[id]) return []
    var candidates = []
    if (colorLuminance(root.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + id + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + id + ".svg"))
    return candidates
  }

  function refreshProvider() {
    // Reload the provider record and reset the logo fallback index.
    root.provider = AskModel.providerFor(root.agentId)
    if (logoMark) logoMark.candidateIndex = 0
  }

  function stopAsk() {
    // TERM the helper; KILL shortly after if it is still running.
    if (!askProc.running) return
    askProc.signal(15)
    askKill.start()
  }

  function resetQuery() {
    // Clear the prompt, answer, and any in-flight ask process.
    root.promptText = ""
    root.summary = ""
    root.errorText = ""
    root.status = "idle"
    root.askBuf = ""
    root.askErrBuf = ""
    root.turns = []
    root.chatSessions = ({})
    root.chatId = ""
    root.chatTitle = ""
    rowsModel.clear()
    root.answerRow = -1
    root.streaming = false
    stopAsk()
  }

  function chatPayload(prompt) {
    // The new message plus earlier answered turns, oldest dropped to fit.
    var history = []
    for (var i = 0; i < root.turns.length; i++)
      if (root.turns[i].a) history.push("User: " + root.turns[i].q + "\nAssistant: " + root.turns[i].a)
    while (history.length) {
      var text = "This continues an earlier conversation:\n\n" + history.join("\n\n")
        + "\n\nReply to the user's new message: " + prompt
      if (text.length <= root.maxChatChars) return text
      history.shift()
    }
    return prompt
  }

  function finishTurn(answer, error) {
    // Fill in the pending (last) turn of the chat.
    root.settleApproval("", 4)
    if (!root.turns.length) return
    var next = root.turns.slice()
    var last = next[next.length - 1]
    next[next.length - 1] = { q: last.q, a: answer || "", error: error || "" }
    root.turns = next
    if (answer) root.showAnswer(answer)
    if (error) root.appendRow("error", error)
    root.answerRow = -1
    root.saveChat()
    if (answer) root.requestTitle()
  }

  function saveChat() {
    // Put this chat at the top of the recent list, with the rows as shown
    // (reopening looks the same) and its session ids (so it can resume).
    // A temporary chat is never saved.
    if (root.tempChat || !root.turns.length) return
    if (!root.chatId) root.chatId = Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
    var rows = []
    for (var i = 0; i < rowsModel.count; i++) {
      var r = rowsModel.get(i)
      rows.push({ kind: r.rowKind, text: r.rowText, count: r.rowCount,
                  steps: r.rowKind === "tool" ? AskModel.trimSteps(r.rowSteps, 1500) : "[]" })
    }
    var entry = { id: root.chatId, title: root.chatTitle || AskModel.clip(root.turns[0].q.replace(/\s+/g, " "), 120),
                  titled: root.chatTitle !== "", agent: root.agentId,
                  updated: Date.now(), sessions: root.chatSessions, turns: root.turns, rows: rows }
    var next = [entry]
    var unpinned = 1
    for (var j = 0; j < root.history.length; j++) {
      var e = root.history[j]
      if (e.id === root.chatId) continue
      var pinned = root.pinnedIds.indexOf(e.id) !== -1
      if (!pinned && unpinned >= root.maxHistory) continue
      if (!pinned) unpinned++
      next.push(e)
    }
    root.writeHistory(next)
  }

  function writeHistory(chats) {
    root.history = chats
    historyFile.setText(JSON.stringify({ version: 1, chats: chats, hidden: root.hiddenSessions,
                                         pinned: root.pinnedIds, prompts: root.promptHistory }) + "\n")
  }

  function togglePin(item) {
    var ids = root.pinnedIds.filter(function(id) { return id !== item.id })
    if (!item.pinned) ids.unshift(item.id)
    root.pinnedIds = ids.slice(0, 100)
    root.writeHistory(root.history)
    root.toast(item.pinned ? "Unpinned" : "Pinned")
  }

  function clearRecent() {
    // Clear everything on the list except pinned chats. Claude's own session
    // files are kept; those sessions are just hidden.
    var keep = root.history.filter(function(e) { return root.pinnedIds.indexOf(e.id) !== -1 })
    var hidden = root.hiddenSessions.slice()
    for (var i = 0; i < root.recentChats.length; i++) {
      var item = root.recentChats[i]
      if (!item.pinned && item.session && hidden.indexOf(item.session) === -1) hidden.unshift(item.session)
    }
    root.hiddenSessions = hidden.slice(0, 500)
    root.clearArmed = false
    root.writeHistory(keep)
    root.toast("Cleared recent chats")
  }

  function requestTitle() {
    // Name this chat from its first question and answer, once.
    if (root.tempChat || root.chatTitle || titleProc.running || !root.turns.length || !root.turns[0].a) return
    root.titleFor = root.chatId
    root.titleBuf = ""
    root.titlePayload = JSON.stringify({ q: root.turns[0].q, a: root.turns[0].a })
    titleProc.running = true
  }

  function applyTitle(id, title) {
    if (!id || !title) return
    if (id === root.chatId) {
      root.chatTitle = title
      root.saveChat()
      return
    }
    // The chat was left meanwhile: rename its saved entry.
    var next = root.history.map(function(e) {
      if (e.id !== id) return e
      var copy = {}
      for (var k in e) copy[k] = e[k]
      copy.title = title
      copy.titled = true
      return copy
    })
    root.writeHistory(next)
  }

  function rememberPrompt(text) {
    if (root.tempChat) return
    var list = root.promptHistory.filter(function(p) { return p !== text })
    list.push(text)
    root.promptHistory = list.slice(-100)
    root.promptIndex = -1
  }

  function recallPrompt(step) {
    // Ctrl+Up / Ctrl+Down: walk back through earlier questions; past the
    // newest one, your unsent text comes back.
    var list = root.promptHistory
    if (!list.length) return
    if (root.promptIndex === -1) {
      if (step > 0) return
      root.promptDraft = promptField.text
      root.promptIndex = list.length - 1
    } else {
      root.promptIndex += step
    }
    if (root.promptIndex < 0) root.promptIndex = 0
    if (root.promptIndex >= list.length) {
      root.promptIndex = -1
      promptField.text = root.promptDraft
      root.toast("Back to your draft")
    } else {
      promptField.text = list[root.promptIndex]
      root.toast("Earlier question  " + (root.promptIndex + 1) + " / " + list.length)
    }
    promptField.cursorPosition = promptField.text.length
  }

  function moveRecent(step) {
    var n = root.recentShown.length
    if (!n) return
    root.recentIndex = Math.max(-1, Math.min(n - 1, root.recentIndex + step))
  }

  function refreshRecent() {
    // Re-read omaSearch's Claude chats (quick: only the start of each file).
    root.recentNow = Date.now()
    if (recentProc.running) return
    root.recentBuf = ""
    recentProc.running = true
  }

  function openRecent(item) {
    // Saved chats open from history.json; Claude chats are rebuilt from
    // Claude's session file first.
    if (item.kind === "saved") {
      root.openChat(item.id)
      return
    }
    if (loadProc.running) return
    root.loadSession = item.session
    root.loadId = item.id
    root.loadBuf = ""
    loadProc.running = true
  }

  function openChat(id) {
    for (var i = 0; i < root.history.length; i++)
      if (root.history[i].id === id) root.openEntry(root.history[i])
  }

  function openEntry(entry) {
    // Reopen a chat as it was. Its agent session resumes on the next
    // message; another agent gets the earlier turns as context instead.
    root.closeMenus()
    root.stopRun()
    root.resetQuery()
    root.tempChat = false
    root.chatId = entry.id
    root.chatTitle = entry.titled ? entry.title : ""
    root.turns = entry.turns
    root.chatSessions = entry.sessions
    for (var r = 0; r < entry.rows.length; r++) {
      var row = entry.rows[r]
      rowsModel.append({ rowKind: row.kind, rowText: row.text, rowFirst: r === 0,
                         rowCount: row.count, rowSteps: row.steps })
    }
    root.summary = root.lastAnswer
    root.status = root.lastAnswer ? "done" : "idle"
    root.askStartedAt = 0
    root.elapsedMs = 0
    root.followTail = true
    root.restartServe()
    promptField.text = ""
    promptField.forceActiveFocus()
    Qt.callLater(root.scrollToEnd)
  }

  function forgetRecent(item) {
    // Take a chat off the recent list. Claude's own session file is kept;
    // its session is just remembered as hidden.
    var next = []
    for (var i = 0; i < root.history.length; i++)
      if (root.history[i].id !== item.id) next.push(root.history[i])
    if (item.session && root.hiddenSessions.indexOf(item.session) === -1)
      root.hiddenSessions = [item.session].concat(root.hiddenSessions).slice(0, 500)
    if (item.id === root.chatId) root.chatId = ""
    root.pinnedIds = root.pinnedIds.filter(function(id) { return id !== item.id })
    root.writeHistory(next)
    root.toast("Removed from recent")
  }

  function appendRow(kind, text, steps) {
    rowsModel.append({ rowKind: kind, rowText: String(text), rowFirst: rowsModel.count === 0,
                       rowCount: 1, rowSteps: JSON.stringify(steps || []) })
  }

  function rowSteps(index) {
    try { return JSON.parse(rowsModel.get(index).rowSteps || "[]") } catch (e) { return [] }
  }

  function appendTool(ev) {
    // One quiet note per command; back-to-back ones collapse into a step count.
    // Each call is kept as a step (what it ran, then its output) for the
    // expanded view.
    root.toolActive = true
    var text = AskModel.clip(ev.text, 200)
    var step = { id: AskModel.clip(ev.id, 80), name: AskModel.clip(ev.name, 80) || "Tool",
                 description: AskModel.clip(ev.description, 200), input: AskModel.clipText(ev.input, 5000),
                 output: "", error: false, done: false }
    var last = rowsModel.count - 1
    if (last >= 0 && rowsModel.get(last).rowKind === "tool") {
      var steps = root.rowSteps(last)
      steps.push(step)
      rowsModel.setProperty(last, "rowCount", rowsModel.get(last).rowCount + 1)
      rowsModel.setProperty(last, "rowText", text)
      rowsModel.setProperty(last, "rowSteps", JSON.stringify(steps))
    } else {
      root.appendRow("tool", text, [step])
    }
    // Text after the command starts a fresh answer row below it.
    root.answerRow = -1
    root.streamText = ""
  }

  function finishTool(ev) {
    // Attach a command's output to its step, matched by the tool call id.
    var id = AskModel.clip(ev.id, 80)
    if (!id) return
    for (var i = rowsModel.count - 1; i >= 0; i--) {
      if (rowsModel.get(i).rowKind !== "tool") continue
      var steps = root.rowSteps(i)
      for (var j = steps.length - 1; j >= 0; j--) {
        if (steps[j].id !== id) continue
        steps[j].output = AskModel.clipText(ev.output, 5000)
        steps[j].error = ev.error === true
        steps[j].done = true
        rowsModel.setProperty(i, "rowSteps", JSON.stringify(steps))
        return
      }
    }
  }

  function setOption(name, value) {
    // Short / Detailed and Safe: saved, then the warm Claude process restarts
    // with them (the chat's session resumes).
    if (root[name] === value) return
    root[name] = value
    settingsFile.setText(JSON.stringify({ detailed: root.detailed, safe: root.safeMode }) + "\n")
    root.restartServe()
    var label = name === "detailed" ? "Detailed answers" : "Safe mode"
    root.toast(label + '  <font color="' + (value ? String(Color.accent) : String(Color.urgent)) + '">'
      + (value ? "on" : "off") + "</font>")
  }

  function appendApproval(ev) {
    // Safe mode: Claude is waiting for your OK to run this.
    var info = { id: AskModel.clip(ev.id, 80), name: AskModel.clip(ev.name, 80) || "Tool",
                 description: AskModel.clip(ev.description, 200), input: AskModel.clipText(ev.input, 5000) }
    var text = AskModel.clip(ev.text, 200)
    root.appendRow("approve", text, [info])
    rowsModel.setProperty(rowsModel.count - 1, "rowCount", 0)
    root.answerRow = -1
    root.streamText = ""
    root.recountApprovals()
    if (!root.opened)
      Quickshell.execDetached(["omarchy", "notification", "send", "omaSearch", "Claude wants to run: " + AskModel.clip(text, 120)])
  }

  function decide(index, allow, always) {
    // Allow / Always / Deny on an approval row. rowCount: 0 waiting,
    // 1 allowed, 2 denied, 3 allowed for this chat, 4 no longer needed.
    var row = rowsModel.get(index)
    if (!row || row.rowKind !== "approve" || row.rowCount !== 0) return
    var info = root.rowSteps(index)[0] || {}
    if (serveProc.running)
      serveProc.write(JSON.stringify({ approve: info.id, allow: allow, always: allow && always }) + "\n")
    rowsModel.setProperty(index, "rowCount", allow ? (always ? 3 : 1) : 2)
    root.recountApprovals()
  }

  function settleApproval(id, state) {
    // Mark a waiting approval (or all of them, id "") as settled.
    for (var i = 0; i < rowsModel.count; i++) {
      var row = rowsModel.get(i)
      if (row.rowKind !== "approve" || row.rowCount !== 0) continue
      if (id && (root.rowSteps(i)[0] || {}).id !== id) continue
      rowsModel.setProperty(i, "rowCount", state)
    }
    root.recountApprovals()
  }

  function recountApprovals() {
    var n = 0
    for (var i = 0; i < rowsModel.count; i++)
      if (rowsModel.get(i).rowKind === "approve" && rowsModel.get(i).rowCount === 0) n++
    root.pendingApprovals = n
  }

  function clearAttachments() {
    root.attachImage = ""
  }

  function pasteClipboard() {
    // Ctrl+V: an image on the clipboard (or a copied image file) is attached
    // for Claude; anything else pastes into the prompt as usual.
    if (pasteProc.running) return
    root.pasteBuf = ""
    pasteProc.running = true
  }

  function showAnswer(text) {
    // Grow the answer row in place as words stream in.
    if (root.answerRow < 0 || root.answerRow >= rowsModel.count) {
      root.appendRow("text", text)
      root.answerRow = rowsModel.count - 1
    } else {
      rowsModel.setProperty(root.answerRow, "rowText", String(text))
    }
  }

  function ensureServe() {
    // Start the warm Claude process (resuming this chat's session if any).
    if (!root.warmAgent || serveProc.running) return
    // A temporary chat never resumes a saved session (there is none).
    var sid = root.tempChat ? "" : (root.chatSessions["claude"] || "")
    root.serveUsed = sid !== ""
    serveProc.command = ["/usr/bin/python3", "-I", "-S", root.askScript, "--serve"]
      .concat(sid ? ["--session", sid] : []).concat(root.modeArgs)
    serveProc.running = true
  }

  function restartServe() {
    // New model / new chat: replace the warm process.
    if (serveProc.running) {
      root.serveRestart = true
      serveProc.signal(15)
    } else if (root.opened) {
      root.ensureServe()
    }
  }

  function stopServe() {
    root.serveRestart = false
    root.servePending = ""
    if (serveProc.running) serveProc.signal(15)
  }

  function sendToServe(payload, image) {
    var line = JSON.stringify(image ? { prompt: payload, image: image } : { prompt: payload }) + "\n"
    if (serveProc.running && root.serveStarted) {
      serveProc.write(line)
    } else {
      root.servePending = line
      root.ensureServe()
    }
  }

  function onServeEvent(raw) {
    var ev
    try { ev = JSON.parse(String(raw)) } catch (e) { return }
    if (!ev || !root.streaming || root.status !== "asking") return
    if (ev.kind === "delta") {
      root.streamText += String(ev.text || "")
      root.showAnswer(root.streamText)
    } else if (ev.kind === "tool") {
      root.appendTool(ev)
    } else if (ev.kind === "tool_result") {
      root.finishTool(ev)
    } else if (ev.kind === "approve") {
      root.appendApproval(ev)
    } else if (ev.kind === "approve_cancel") {
      root.settleApproval(AskModel.clip(ev.id, 80), 4)
    } else if (ev.kind === "done") {
      root.streaming = false
      root.markElapsed()
      if (ev.ok && ev.summary) {
        var session = /^[A-Za-z0-9_-]{1,80}$/.test(String(ev.session || "")) ? String(ev.session) : ""
        if (session) {
          var sessions = ({})
          for (var k in root.chatSessions) sessions[k] = root.chatSessions[k]
          sessions["claude"] = session
          root.chatSessions = sessions
        }
        root.summary = AskModel.clipText(ev.summary, 6000)
        root.errorText = ""
        root.status = "done"
        root.finishTurn(root.summary, "")
      } else {
        root.fail(ev.error || "No answer.")
      }
      if (!root.opened) root.notifyDone()
    } else if (ev.kind === "exit") {
      root.streaming = false
      root.fail(ev.error || "Claude stopped unexpectedly.")
      if (!root.opened) root.notifyDone()
    }
  }

  function open(payloadJson) {
    // Show the overlay; optional JSON `{ "prompt": "..." }` pre-fills the field.
    var payload = ({})
    try { payload = JSON.parse(AskModel.clip(payloadJson || "{}", 4096)) } catch (e) { payload = ({}) }
    root.closeMenus()
    root.refreshAgent()
    root.refreshAgents()
    root.refreshModels()
    root.refreshProvider()
    root.refreshRecent()
    // Boot Claude now, while you type. The chat stays until New ^N; a payload
    // prompt only pre-fills the pill.
    root.ensureServe()
    if (payload.prompt) promptField.text = AskModel.clipText(payload.prompt, root.maxPrompt)
    root.opened = true
    Qt.callLater(function() {
      root.scrollToEnd()
      promptField.forceActiveFocus()
      promptField.selectAll()
    })
  }

  function close() {
    // Hide the overlay; a running answer keeps going and notifies when done.
    root.closeMenus()
    root.opened = false
  }

  function dismiss() {
    // Hide the overlay and notify omarchy-shell so IPC state stays in sync.
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.5h3rd1l.omasearch")
  }

  function toggle() {
    // IPC toggle: close if open, otherwise open empty.
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function submit() {
    // Run ask.py with the current field text on stdin.
    var prompt = AskModel.clipText(promptField.text || root.promptText || "", root.maxPrompt).replace(/^\s+|\s+$/g, "")
    if (root.asking) return
    // An image alone still asks something sensible.
    if (!prompt && root.attachImage) prompt = "What is this?"
    if (!prompt) return
    var image = root.warmAgent ? root.attachImage : ""
    var note = image ? "\u25a3 image" : ""
    root.clearAttachments()
    root.askPrompt = prompt
    // A live session already holds the history; otherwise send it along.
    root.askSession = root.currentSession
    root.askPayload = root.askSession ? prompt : root.chatPayload(prompt)
    var warmPayload = root.serveUsed ? prompt : root.chatPayload(prompt)
    root.turns = root.turns.concat([{ q: prompt, a: "", error: "" }])
    root.appendRow("you", note ? prompt + "\n" + note : prompt)
    root.rememberPrompt(prompt)
    root.answerRow = -1
    root.toolActive = false
    root.promptText = ""
    promptField.text = ""
    root.summary = ""
    root.errorText = ""
    root.askBuf = ""
    root.askErrBuf = ""
    root.status = "asking"
    root.followTail = true
    root.askStartedAt = Date.now()
    root.elapsedMs = 0
    if (root.warmAgent) {
      root.streaming = true
      root.streamText = ""
      root.serveUsed = true
      root.sendToServe(warmPayload, image)
      return
    }
    if (askProc.running) {
      askProc.signal(15)
      askKill.start()
    }
    askProc.stdinEnabled = true
    askProc.running = true
  }

  function fail(message) {
    // Show an error in the overlay body.
    root.status = "error"
    root.errorText = AskModel.clip(message || "Something went wrong.", 240)
    root.finishTurn("", root.errorText)
  }

  function onAskFinished(raw) {
    // Apply ask.py JSON: answer, open-browser hint, or error.
    var data = AskModel.parseAskOutput(raw)
    if (data.agent) {
      root.agentId = data.agent
      root.provider = AskModel.providerFor(data.agent)
    }
    if (data.ok && data.session && data.agent) {
      var sessions = ({})
      for (var k in root.chatSessions) sessions[k] = root.chatSessions[k]
      sessions[data.agent] = data.session
      root.chatSessions = sessions
    }
    if (data.ok && data.summary) {
      root.summary = data.summary
      root.errorText = ""
      root.status = "done"
      root.finishTurn(data.summary, "")
      return
    }
    if (data.code === "open-browser") {
      root.summary = ""
      root.fail(data.error || "Open the browser to ask this agent.")
      return
    }
    root.fail(data.error || "No answer.")
  }

  function closeMenus() {
    root.pickerOpen = false
    root.modelPickerOpen = false
    root.helpOpen = false
  }

  function toast(text) {
    root.toastText = String(text)
    root.toastShown = true
    toastTimer.restart()
  }

  function toggleHelp() {
    var show = !root.helpOpen
    root.closeMenus()
    root.helpOpen = show
    promptField.forceActiveFocus()
  }

  function scrollToEnd() {
    list.contentY = Math.max(0, list.contentHeight - list.height)
  }

  function noteSelection(edit) {
    // Only one piece of chat text keeps a selection at a time. Selecting
    // copies: once the selection stops changing, it goes to the clipboard.
    if (edit.selectedText !== "") {
      var old = root.selectionOwner
      root.selectionOwner = edit
      if (old && old !== edit) old.deselect()
      selectionCopy.restart()
    } else if (root.selectionOwner === edit) {
      root.selectionOwner = null
      root.selectionClearedAt = Date.now()
    }
  }

  function clearSelection() {
    if (root.selectionOwner && root.selectionOwner.selectedText !== "") root.selectionOwner.deselect()
  }

  function copySelection() {
    // Ctrl+C with text selected in the chat copies it.
    var text = root.selectionOwner ? AskModel.plainSelection(root.selectionOwner.selectedText) : ""
    if (!text) return false
    root.copyText(text)
    return true
  }

  function chatClick(edit, text) {
    // A click on a message / answer / code block: drop a selection held
    // elsewhere, collapse open tool rows, and copy the whole piece.
    if (root.selectionOwner && root.selectionOwner !== edit) root.clearSelection()
    root.collapseTools()
    root.queueCopy(text)
  }

  function queueCollapse(edit, item) {
    // A click on a command / output closes its tool row. Like queueCopy it
    // waits out the double-click time, so selecting a word or line (or a
    // click that just clears a selection) leaves the row open.
    if (root.selectionOwner && root.selectionOwner !== edit) root.clearSelection()
    root.pendingCollapse = item
    collapseTimer.restart()
  }

  function queueCopy(text) {
    // A single click copies the whole message (or code block / command /
    // output). It waits out the double-click time: if that click was
    // selecting a word or line, or clearing a selection, nothing is copied.
    root.pendingCopy = String(text || "")
    copyTimer.restart()
  }

  function clampScroll() {
    // Content shrank (a row collapsed) or the card grew: no blank space below.
    list.contentY = Math.max(0, Math.min(list.contentY, list.contentHeight - list.height))
  }

  function revealRow(item) {
    // Scroll a just-expanded tool row into view, keeping its header visible.
    if (!item) return
    var bottom = item.y + item.height
    if (bottom > list.contentY + list.height) list.contentY = Math.min(item.y, bottom - list.height)
    if (item.y < list.contentY) list.contentY = item.y
    root.clampScroll()
  }

  function toggleTool(item) {
    // Opening scrolls the details into view; closing a long one from its
    // bottom scrolls back up to its summary line.
    // Stop following the bottom first: the size change must not scroll there.
    // (Text lays out a moment later, so don't re-check "at the bottom" here.)
    root.followTail = false
    item.expanded = !item.expanded
    Qt.callLater(root.revealRow, item)
  }

  function formatElapsed(ms) {
    var seconds = Math.round(ms / 1000)
    if (seconds <= 0) return ""
    if (seconds < 60) return seconds + "s"
    return Math.floor(seconds / 60) + "m " + ("0" + (seconds % 60)).slice(-2) + "s"
  }

  function markElapsed() {
    if (root.askStartedAt > 0) root.elapsedMs = Date.now() - root.askStartedAt
  }

  function copyLast() {
    if (root.lastAnswer) root.copyText(root.lastAnswer)
  }

  function stopRun() {
    // Ctrl+C / Stop: abandon the running answer.
    if (!root.asking) return
    root.toast("Stopped")
    root.markElapsed()
    root.status = "idle"
    root.stopAsk()
    if (root.streaming) {
      root.streaming = false
      root.restartServe()
    }
    root.finishTurn("", "Stopped")
  }

  function newChat() {
    // Ctrl+N / New: forget this chat and its sessions (and leave a temporary chat).
    root.closeMenus()
    root.tempChat = false
    root.resetQuery()
    root.restartServe()
    promptField.text = ""
    root.askStartedAt = 0
    root.elapsedMs = 0
    root.followTail = true
    root.refreshRecent()
    root.toast("New chat")
    promptField.forceActiveFocus()
  }

  function toggleTemp() {
    // Ctrl+I: start a temporary chat, or end the one you're in and start a
    // normal one. The temporary chat is gone once it ends.
    var on = !root.tempChat
    root.closeMenus()
    root.resetQuery()
    root.tempChat = on
    root.restartServe()
    promptField.text = ""
    root.askStartedAt = 0
    root.elapsedMs = 0
    root.followTail = true
    if (!on) root.refreshRecent()
    root.toast(on ? '<font color="' + String(Color.accent) + '">\uf21b</font>  Temporary chat \u00b7 nothing is saved'
                  : "Temporary chat ended")
    promptField.forceActiveFocus()
  }

  function savePosition() {
    positionFile.setText(JSON.stringify({ dragX: root.dragX, dragY: root.dragY }) + "\n")
  }

  function notifyDone() {
    // An answer finished while omaSearch was hidden.
    var last = root.turns.length ? root.turns[root.turns.length - 1] : null
    var text = last ? (last.a || last.error) : ""
    if (text) Quickshell.execDetached(["omarchy", "notification", "send", "omaSearch", AskModel.clip(text, 140)])
  }

  function copyText(value) {
    // Copy via stdin to open_chat.py --copy (wl-copy argv never sees the text).
    var text = AskModel.clipText(value, 12000)
    if (!text) return
    root.copyPayload = text
    if (copyProc.running) copyProc.signal(15)
    copyProc.stdinEnabled = true
    copyProc.running = true
    root.copied = true
    copyFlash.restart()
    root.toast("\u2713 Copied")
  }

  function openLink(url) {
    // A link in an answer: open it in the default browser (http / https only).
    if (!/^https?:\/\/[^\s]+$/.test(String(url))) return
    Quickshell.execDetached(["omarchy", "launch", "browser", String(url)])
    root.dismiss()
  }

  function searchGoogle() {
    // Search the typed question on Google in the default browser (Omarchy's
    // launcher opens it and brings it forward), then close.
    // One line for Google: line breaks become spaces.
    var query = AskModel.clip(String(promptField.text || root.promptText || root.askPrompt || "").replace(/\s+/g, " "),
                              root.maxPrompt).trim()
    if (!query) return
    var url = "https://www.google.com/search?q=" + encodeURIComponent(query)
    Quickshell.execDetached(["omarchy", "launch", "browser", url])
    root.dismiss()
  }

  function openTerminal() {
    // Continue this chat's session in the agent's TUI, in $HOME where it was created.
    if (root.tempChat) return
    var sid = root.currentSession
    var agent = AskModel.normalizeAgent(root.agentId)
    var cmd = agent === "claude" ? ["claude", "--resume", sid]
      : agent === "codex" ? ["codex", "resume", sid]
      : agent === "opencode" ? ["opencode", "-s", sid]
      : []
    if (!sid || !cmd.length) return
    // Hand the session over: the terminal owns it now; omaSearch resumes it later.
    if (agent === "claude") root.stopServe()
    var home = Quickshell.env("HOME")
    Quickshell.execDetached(["xdg-terminal-exec", "--dir=" + home, "--",
      "/usr/bin/bash", "-lc", 'exec "$@"', "omasearch"].concat(cmd))
    root.dismiss()
  }

  function openBrowser() {
    // Hand off prompt + overlay answer on stdin as JSON; argv is only --agent.
    // Delay dismiss + stdin close so the JSON is not truncated and exclusive
    // keyboard focus is gone before the helper types into Chromium.
    var prompt = AskModel.clip(root.askPrompt || root.promptText || promptField.text || "", root.maxPrompt)
    root.askPrompt = prompt
    root.browserPayload = JSON.stringify({
      prompt: prompt,
      answer: AskModel.clip(root.summary, 720)
    })
    root.browserAgent = AskModel.normalizeAgent(root.provider && root.provider.id ? root.provider.id : "")
    if (browserProc.running) browserProc.signal(15)
    browserProc.stdinEnabled = true
    browserProc.running = true
    browserFlush.restart()
  }

  function refreshAgents() {
    // Installed agents for the logo menu, via ask.py --list.
    if (listProc.running) return
    root.listBuf = ""
    listProc.running = true
  }

  function refreshModels() {
    // Models for the current agent via ask.py --models (cached by ask.py).
    if (!root.agentId) return
    if (modelsProc.running) {
      if (root.modelsAgent === root.agentId) return
      modelsProc.signal(15)
      return  // onExited starts it again for the new agent
    }
    root.modelsBuf = ""
    root.modelsAgent = root.agentId
    modelsProc.running = true
  }

  function selectModel(id) {
    // Use this model for the current agent from now on.
    root.modelPickerOpen = false
    if (root.asking) return
    var model = AskModel.clip(id, 128)
    if (model !== root.modelId) {
      root.modelId = model
      root.summary = ""
      root.errorText = ""
      root.status = "idle"
      root.pendingModelAgent = root.agentId
      root.pendingModel = model
      if (!selectModelProc.running) selectModelProc.running = true
      root.toast("Model  " + AskModel.escapeHtml(root.modelName))
    }
    Qt.callLater(function() { promptField.forceActiveFocus() })
  }

  onAgentIdChanged: {
    root.models = []
    root.modelId = ""
    root.refreshModels()
    if (root.opened) {
      if (root.warmAgent) root.ensureServe()
      else root.stopServe()
    }
  }

  function selectAgent(id) {
    // Use this agent from now on (saved by ask.py --select).
    var agent = AskModel.normalizeAgent(id)
    root.pickerOpen = false
    if (!agent || root.asking) return
    if (agent !== root.agentId) {
      root.agentId = agent
      root.refreshProvider()
      root.summary = ""
      root.errorText = ""
      root.status = "idle"
      root.pendingSelect = agent
      if (!selectProc.running) selectProc.running = true
    }
    Qt.callLater(function() { promptField.forceActiveFocus() })
  }

  function refreshAgent() {
    // Re-read the default-agent file through ask.py --info (not FileView.text).
    if (infoProc.running) {
      infoProc.signal(15)
      infoKill.start()
    }
    infoBuf = ""
    infoProc.running = true
  }

  property string infoBuf: ""

  FileView {
    id: agentFile
    path: root.agentFilePath
    preload: false
    blockAllReads: true
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshAgent()
  }

  Process {
    id: infoProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--info"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(chunk) {
        if (root.infoBuf.length + String(chunk).length > 2048) {
          infoProc.signal(15)
          infoKill.start()
          return
        }
        root.infoBuf += chunk
      }
    }
    onExited: function() {
      // --info is fast; wait a tick so SplitParser can flush the JSON line.
      Qt.callLater(function() {
        var data = AskModel.parseAskOutput(root.infoBuf)
        root.infoBuf = ""
        if (data.agent) root.agentId = data.agent
        root.refreshProvider()
      })
    }
  }

  Process {
    id: listProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--list"]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(chunk) {
        if (root.listBuf.length + String(chunk).length <= 4096) root.listBuf += chunk
      }
    }
    onExited: function() {
      Qt.callLater(function() {
        var list = []
        try {
          var raw = JSON.parse(root.listBuf).agents || []
          for (var i = 0; i < raw.length && list.length < 16; i++) {
            var id = AskModel.normalizeAgent(raw[i].id)
            if (id) list.push({ id: id, name: AskModel.providerFor(id).name })
          }
        } catch (e) {}
        root.listBuf = ""
        root.agents = list
      })
    }
  }

  Process {
    id: modelsProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--models", root.modelsAgent]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.modelsBuf.length + String(chunk).length <= 16384) root.modelsBuf += chunk
      }
    }
    onExited: function() {
      Qt.callLater(function() {
        if (root.modelsAgent !== root.agentId) {
          root.refreshModels()
          return
        }
        var list = []
        var selected = ""
        try {
          var data = JSON.parse(root.modelsBuf)
          var raw = data.models || []
          for (var i = 0; i < raw.length && list.length < 61; i++)
            list.push({ id: AskModel.clip(raw[i].id, 128), name: AskModel.clip(raw[i].name, 60) })
          selected = AskModel.clip(data.selected, 128)
        } catch (e) {}
        root.modelsBuf = ""
        root.models = list
        root.modelId = selected
      })
    }
  }

  Process {
    id: selectModelProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--select-model", root.pendingModelAgent, root.pendingModel]
    // The warm process picks its model at start: restart it on the new one.
    onExited: if (root.pendingModelAgent === "claude" && root.warmAgent) root.restartServe()
  }

  Process {
    id: selectProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--select", root.pendingSelect]
  }

  Process {
    id: copyProc
    command: ["/usr/bin/python3", "-I", "-S", root.pluginDir + "/open_chat.py", "--copy"]
    stdinEnabled: true
    onStarted: {
      copyProc.write(root.copyPayload)
      copyProc.stdinEnabled = false
    }
  }

  Process {
    id: browserProc
    command: ["/usr/bin/python3", "-I", "-S", root.pluginDir + "/open_chat.py", "--agent", root.browserAgent]
    stdinEnabled: true
    onStarted: browserProc.write(root.browserPayload)
  }

  Timer {
    id: browserFlush
    interval: 150
    repeat: false
    onTriggered: {
      if (browserProc.running) browserProc.stdinEnabled = false
      root.dismiss()
    }
  }

  Process {
    id: askProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript]
      .concat(root.agentId ? ["--agent", root.agentId] : [])
      .concat(root.askSession ? ["--session", root.askSession] : [])
      .concat(root.modeArgs).concat(["--ask"])
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.askBuf.length + String(chunk).length > root.maxAskBytes) {
          root.stopAsk()
          root.fail("Answer was too large.")
          return
        }
        root.askBuf += chunk
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.askErrBuf.length + String(chunk).length > 1024) {
          root.stopAsk()
          return
        }
        root.askErrBuf += chunk
      }
    }
    onStarted: {
      askProc.write(root.askPayload)
      askProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      askKill.stop()
      if (root.status !== "asking") return
      root.markElapsed()
      if (root.askBuf.replace(/^\s+|\s+$/g, "")) {
        root.onAskFinished(root.askBuf)
      } else {
        var err = AskModel.clip(root.askErrBuf, 240)
        root.fail(err || ("Ask helper exited " + exitCode + "."))
      }
      if (!root.opened) root.notifyDone()
    }
  }

  Timer {
    interval: 500
    repeat: true
    running: root.asking
    onTriggered: root.markElapsed()
  }

  Timer {
    id: copyFlash
    interval: 1200
    onTriggered: root.copied = false
  }

  FileView {
    id: themeColorsFile
    path: root.themeColorsPath
    watchChanges: true
    printErrors: false
    onFileChanged: themeColorsFile.reload()
    onLoaded: {
      var pal = {}
      var lines = themeColorsFile.text().split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = /^\s*(red|green|yellow|blue|magenta|cyan)\s*=\s*"(#[0-9a-fA-F]{6})"/.exec(lines[i])
        if (m) pal[m[1]] = m[2]
      }
      root.themePalette = pal
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var o = JSON.parse(settingsFile.text())
        root.detailed = o.detailed === true
        root.safeMode = o.safe !== false
      } catch (e) {}
    }
  }

  // Ctrl+V: save a clipboard image (PNG / JPEG / WebP / GIF, or a copied
  // image file) into the private folder and print IMG:<path>; BIG if it is
  // over Claude's 5 MB limit; TEXT when there is no image to take.
  Process {
    id: pasteProc
    command: ["/usr/bin/bash", "--noprofile", "--norc", "-c",
      'umask 077; d="$1"; mkdir -p "$d" && find "$d" -name "shot-*" -mmin +60 -delete; '
      + 'types=$(wl-paste --list-types 2>/dev/null) || { echo TEXT; exit 0; }; '
      + 'save() { s=$(stat -c %s "$1"); if [ "$s" -gt 5242880 ]; then rm -f "$1"; echo BIG; exit 0; fi; printf "IMG:%s" "$1"; exit 0; }; '
      + 'for t in image/png image/jpeg image/webp image/gif; do '
      + '  if printf "%s\\n" "$types" | grep -qx "$t"; then '
      + '    e=${t#image/}; [ "$e" = jpeg ] && e=jpg; f="$d/shot-$(date +%s%N).$e"; '
      + '    wl-paste --type "$t" > "$f" 2>/dev/null && save "$f"; rm -f "$f"; echo TEXT; exit 0; '
      + '  fi; '
      + 'done; '
      + 'if printf "%s\\n" "$types" | grep -qx "text/uri-list"; then '
      + '  u=$(wl-paste --type text/uri-list 2>/dev/null | tr -d "\\r" | grep -m1 "^file://"); p=${u#file://}; '
      + '  p=$(printf "%b" "${p//%/\\\\x}"); e=${p##*.}; e=$(printf "%s" "$e" | tr "A-Z" "a-z"); [ "$e" = jpeg ] && e=jpg; '
      + '  case "$e" in png|jpg|webp|gif) if [ -f "$p" ]; then f="$d/shot-$(date +%s%N).$e"; cp -- "$p" "$f" && save "$f"; fi;; esac; '
      + 'fi; '
      + 'echo TEXT',
      "omasearch", root.shotsDir]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { if (root.pasteBuf.length < 4096) root.pasteBuf += chunk }
    }
    onExited: {
      var out = root.pasteBuf.replace(/^\s+|\s+$/g, "")
      if (out.indexOf("IMG:" + root.shotsDir + "/shot-") === 0) {
        root.attachImage = out.slice(4)
        root.toast("\u25a3 Image attached")
      } else if (out === "BIG") {
        root.toast('<font color="' + String(Color.urgent) + '">Image is over 5 MB</font> (Claude\'s limit)')
      } else {
        promptField.paste()
      }
      promptField.forceActiveFocus()
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.history = AskModel.parseHistory(historyFile.text(), 200)
      root.hiddenSessions = AskModel.parseHidden(historyFile.text())
      root.pinnedIds = AskModel.parseIds(historyFile.text(), "pinned")
      root.promptHistory = AskModel.parsePrompts(historyFile.text())
    }
  }

  Process {
    id: titleProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--title"]
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { if (root.titleBuf.length < 4096) root.titleBuf += chunk }
    }
    onStarted: {
      titleProc.write(root.titlePayload)
      titleProc.stdinEnabled = false
    }
    onExited: {
      titleProc.stdinEnabled = true
      try {
        var data = JSON.parse(root.titleBuf)
        root.applyTitle(root.titleFor, AskModel.clip(data.title, 60))
      } catch (e) {}
    }
  }

  Process {
    id: recentProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--recent-claude"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.recentBuf.length < 262144) root.recentBuf += chunk
      }
    }
    onExited: {
      try {
        var data = JSON.parse(root.recentBuf)
        if (data && Array.isArray(data.chats)) root.claudeRecent = data.chats
      } catch (e) {}
      root.recentNow = Date.now()
    }
  }

  Process {
    id: loadProc
    command: ["/usr/bin/python3", "-I", "-S", root.askScript, "--load-claude", root.loadSession]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.loadBuf.length < 4194304) root.loadBuf += chunk
      }
    }
    onExited: {
      var data = null
      try { data = JSON.parse(root.loadBuf) } catch (e) {}
      if (!data || !data.ok) return
      var entry = AskModel.parseHistory(JSON.stringify({ chats: [data.chat] }), 1)[0]
      if (!entry) return
      // Keep the saved chat's id (if any), so going on updates that entry.
      entry.id = root.loadId
      root.openEntry(entry)
    }
  }

  FileView {
    id: positionFile
    path: root.positionPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var pos = JSON.parse(text())
        root.dragX = Number(pos.dragX) || 0
        root.dragY = Number(pos.dragY) || 0
      } catch (e) {}
    }
  }

  Timer {
    id: askKill
    interval: 2000
    repeat: false
    onTriggered: if (askProc.running) askProc.signal(9)
  }

  Timer {
    id: infoKill
    interval: 2000
    repeat: false
    onTriggered: if (infoProc.running) infoProc.signal(9)
  }

  Timer {
    id: askDeadline
    interval: 600000
    repeat: false
    running: root.asking
    onTriggered: if (root.status === "asking") root.stopRun()
  }

  ListModel { id: rowsModel }

  Timer {
    id: selectionCopy
    interval: 250
    onTriggered: root.copySelection()
  }

  Timer {
    id: collapseTimer
    interval: Qt.styleHints.mouseDoubleClickInterval + 50
    onTriggered: {
      var item = root.pendingCollapse
      root.pendingCollapse = null
      if (!item || !item.expanded) return
      if (root.selectionOwner || Date.now() - root.selectionClearedAt < 1000) return
      root.toggleTool(item)
    }
  }

  Timer {
    id: toastTimer
    interval: 1300
    onTriggered: root.toastShown = false
  }

  Timer {
    id: copyTimer
    interval: Qt.styleHints.mouseDoubleClickInterval + 50
    onTriggered: {
      // Skip it when the click was selecting text or clearing a selection.
      if (root.selectionOwner || Date.now() - root.selectionClearedAt < 1000) return
      root.copyText(root.pendingCopy)
    }
  }

  Process {
    id: serveProc
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.onServeEvent(line) }
    }
    onStarted: {
      root.serveStarted = true
      if (root.servePending) {
        serveProc.write(root.servePending)
        root.servePending = ""
      }
    }
    onExited: function() {
      root.serveStarted = false
      root.serveUsed = false
      if (root.streaming && root.status === "asking") {
        root.streaming = false
        root.fail("Claude stopped unexpectedly.")
      }
      if (root.serveRestart) {
        root.serveRestart = false
        if (root.opened || root.servePending) Qt.callLater(root.ensureServe)
      }
    }
  }

  // Free the warm process after 10 minutes closed.
  Timer {
    interval: 600000
    running: !root.opened && !root.asking && serveProc.running
    onTriggered: root.stopServe()
  }

  onAskScriptChanged: root.refreshAgent()
  Component.onCompleted: {
    // Chat history and settings live here: private to you (0700).
    Quickshell.execDetached(["/usr/bin/bash", "--noprofile", "--norc", "-c", 'mkdir -p -m 700 "$1" && chmod 700 "$1"',
      "omasearch", Quickshell.env("HOME") + "/.local/state/omasearch"])
    root.refreshAgent()
    root.refreshAgents()
  }
  Component.onDestruction: {
    root.stopAsk()
    if (serveProc.running) serveProc.signal(15)
    if (infoProc.running) infoProc.signal(15)
    if (copyProc.running) copyProc.signal(15)
    if (browserProc.running) browserProc.signal(15)
  }

  // Omagent-style surfaces: a frosted pill for the input and a frosted card for
  // the chat above it, so the reply box stays at the bottom. The pill alone, or
  // card + pill together, sit centred on screen and glide as the card grows.
  // Agent and model menus pop up above the pill.
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omasearch"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    readonly property int gap: Style.space(12)
    readonly property int surfaceWidth: Math.min(Style.space(640), panel.width - Style.space(32))
    readonly property bool chatting: root.turns.length > 0
    readonly property int cardMax: Math.max(
      Style.space(80),
      Math.min(Math.round(panel.height * 0.6),
               panel.height - pill.height - panel.below - panel.gap - Style.space(48)))
    // Height the card is heading for (card.height animates towards it).
    readonly property int cardTarget: panel.chatting
      ? Math.min(card.contentTopInset + card.contentBottomInset
                   + header.height + Style.space(12)
                   + rows.height,
                 panel.cardMax)
      : 0
    // No chat open: recent chats hang under the hint bar.
    readonly property bool showRecent: !panel.chatting && !root.tempChat && root.recentShown.length > 0
    readonly property int above: panel.chatting ? panel.cardTarget + panel.gap : 0
    // The hint / action bar under the pill.
    readonly property int below: hints.height + Style.space(8)
    readonly property int pillTop: Math.round((panel.height - panel.above - pill.height - panel.below) / 2) + panel.above
    readonly property int pillY: panel.pillTop + panel.clampY(root.dragY)
    readonly property int surfaceX: Math.round((panel.width - panel.surfaceWidth) / 2) + panel.clampX(root.dragX)

    function clampX(value) {
      var slack = Math.round((panel.width - panel.surfaceWidth) / 2) - Style.space(8)
      return Math.max(-slack, Math.min(slack, value))
    }

    function clampY(value) {
      // Keep the card (above the pill), the pill and the bar under it on screen.
      return Math.max(Style.space(8) + panel.above - panel.pillTop,
                      Math.min(panel.height - Style.space(8) - panel.pillTop - pill.height - panel.below, value))
    }

    // Limits apply where x/y are bound (and while dragging). Never write a
    // clamped value back on open: the first open runs before the window is
    // sized, and clamping then pushed the pill 46px below centre.

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Color.menu.scrim.r, Color.menu.scrim.g, Color.menu.scrim.b, 1)
      // Below omasearch's blur cutoff (ignore_alpha 0.45), so the backdrop stays sharp.
      opacity: root.opened ? 0.4 : 0
    }

    MouseArea {
      anchors.fill: parent
      onClicked: {
        if (root.menuOpen) root.closeMenus()
        else root.dismiss()
      }
    }

    // Conversation card, above the pill.
    BorderSurface {
      id: card

      visible: panel.chatting
      width: panel.surfaceWidth
      x: panel.surfaceX
      y: pill.y - panel.gap - card.height
      height: panel.cardTarget
      radius: Style.space(20)
      // Glass: a translucent tint the compositor blurs behind.
      color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0.55)
      borderSpec: Border.none()
      padding: Style.space(14)
      // Hidden while the help panel is open, so its text reads cleanly.
      opacity: root.opened && !root.helpOpen ? 1 : 0
      enabled: !root.helpOpen

      GlassSheen {
        radius: card.radius
      }

      Behavior on height {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: {
          root.closeMenus()
          root.collapseTools()
          root.clearSelection()
          promptField.forceActiveFocus()
        }
      }

      Item {
        anchors.fill: parent
        anchors.margins: card.contentTopInset

        Item {
          id: header
          width: parent.width
          height: Style.space(20)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              text: root.provider && root.provider.name ? root.provider.name : "omaSearch"
              color: Color.menu.text
              opacity: 0.86
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: stateLabel.text !== ""
              text: "·"
              color: root.subtle
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: stateLabel
              text: root.pendingApprovals > 0 ? "Waiting for you"
                : root.chatState === "asking" ? (root.toolActive ? "Working…" : "Thinking…")
                : root.chatState === "stopped" ? "Stopped"
                : root.chatState === "failed" ? "Failed"
                : root.chatState === "done" ? "Done" : ""
              color: root.chatState === "failed" ? Color.urgent : root.subtle
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Marks a temporary chat (Ctrl+I): nothing here is saved.
            Text {
              visible: root.tempChat
              text: "·"
              color: root.subtle
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: root.tempChat
              text: "\uf21b  Temporary"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.formatElapsed(root.elapsedMs)
            visible: text !== ""
            color: root.subtle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Flickable {
          id: list

          anchors.top: header.bottom
          anchors.topMargin: Style.space(12)
          anchors.bottom: parent.bottom
          width: parent.width
          clip: true
          contentWidth: width
          contentHeight: rows.height
          boundsBehavior: Flickable.StopAtBounds
          // Mouse drags select text; the wheel / touchpad still scrolls.
          acceptedButtons: Qt.NoButton

          onMovementEnded: root.followTail = list.atYEnd
          onContentHeightChanged: root.followTail ? root.scrollToEnd() : root.clampScroll()
          onHeightChanged: root.followTail ? root.scrollToEnd() : root.clampScroll()

          // A click on a tool row expands / collapses it: its summary line
          // toggles, anywhere in its open details closes it (unless the click
          // just cleared a selection). A click anywhere else collapses them all.
          // Clicks on the text itself arrive via ChatText.clicked instead.
          TapHandler {
            id: listTap
            onTapped: function(eventPoint) {
              var hadSelection = root.selectionOwner !== null
              root.clearSelection()
              var p = rows.mapFromItem(listTap.parent, eventPoint.position.x, eventPoint.position.y)
              var hit = rows.childAt(p.x, p.y)
              if (hit && hit.isTool) {
                if (p.y - hit.y <= hit.headerHeight || !hadSelection) root.toggleTool(hit)
                return
              }
              root.collapseTools()
            }
          }

          Column {
            id: rows
            // Keep text clear of the scroll bar on the right. Always reserved, so
            // text doesn't re-wrap when the chat starts to scroll.
            width: list.width - Style.space(12)
            spacing: Style.space(8)

            Repeater {
              model: rowsModel

              delegate: Item {
                id: row

                required property string rowKind
                required property string rowText
                required property bool rowFirst
                required property int rowCount
                required property string rowSteps
                required property int index

                // Tool rows: click the summary line to show each command and its output.
                property bool expanded: false
                readonly property var steps: {
                  if (!row.isTool || !row.expanded) return []
                  try { return JSON.parse(row.rowSteps) } catch (e) { return [] }
                }
                readonly property int headerHeight: label.y + label.contentHeight + Style.space(3)

                readonly property bool isYou: row.rowKind === "you"
                readonly property bool isError: row.rowKind === "error"
                readonly property bool isTool: row.rowKind === "tool"
                // Safe mode: a command waiting for (or given) your OK.
                readonly property bool isApprove: row.rowKind === "approve"
                readonly property var approvalInfo: {
                  if (!row.isApprove) return ({})
                  try { return JSON.parse(row.rowSteps)[0] || ({}) } catch (e) { return ({}) }
                }
                // Answers are markdown: laid out as paragraphs, lists and code blocks.
                readonly property bool isAnswer: row.rowKind === "text"
                readonly property var segments: row.isAnswer
                  ? AskModel.answerSegments(row.rowText, {
                      code: String(Color.accent), dim: String(root.subtle), note: String(root.note),
                      charWidth: metrics.averageCharacterWidth, blankPx: Math.round(metrics.height * row.leading),
                      leadingPct: Math.round(row.leading * 100), bodyPx: Style.font.body,
                      titlePx: Style.font.title, quotePx: Style.space(12) })
                  : []
                readonly property int padX: row.isYou ? Style.space(10) : 0
                readonly property int padY: row.isYou ? Style.space(7) : 0
                readonly property int leadIn: (row.isYou && !row.rowFirst) ? Style.space(14) : 0
                readonly property int opticalShift: row.isYou
                  ? Math.round((metrics.descent - (metrics.ascent - metrics.capHeight)) / 2)
                  : 0
                readonly property real leading: 1.35
                readonly property int trailing: row.isAnswer ? Math.round(metrics.height * (row.leading - 1)) : 0
                readonly property int chipWidth: Math.min(label.contentWidth + row.padX * 2, rows.width)

                width: rows.width
                height: row.isApprove ? approval.height
                  : row.isAnswer ? answer.height
                  : row.isTool && row.expanded ? detail.y + detail.height + Style.space(4)
                  : row.leadIn + (row.isTool ? label.contentHeight : msg.contentHeight) + row.padY * 2

                Connections {
                  target: root
                  function onCollapseTools() { row.expanded = false }
                }

                FontMetrics {
                  id: metrics
                  font: label.font
                }

                // Your message sits in a chip; answers are plain prose.
                Rectangle {
                  visible: row.isYou
                  y: row.leadIn
                  width: row.chipWidth
                  height: parent.height - row.leadIn
                  radius: Style.cornerRadius
                  color: Color.menu.selectedBackground
                }

                Rectangle {
                  visible: row.isError
                  x: -Style.space(9)
                  y: row.leadIn + Style.space(1)
                  width: Math.max(2, Style.space(2))
                  height: parent.height - row.leadIn - Style.space(2)
                  radius: width / 2
                  color: Color.urgent
                }

                // Hover wash; click any message to copy it.
                Rectangle {
                  y: row.leadIn + (row.isYou ? 0 : -Style.space(2))
                  x: row.isYou ? 0 : -Style.space(5)
                  width: row.isYou ? row.chipWidth : rows.width + Style.space(10)
                  height: (row.isTool ? label.contentHeight : parent.height - row.leadIn) + (row.isYou ? 0 : Style.space(4))
                  radius: Style.cornerRadius
                  color: Color.menu.text
                  opacity: hover.hovered && !row.isApprove ? 0.06 : 0

                  Behavior on opacity {
                    NumberAnimation { duration: 100 }
                  }
                }

                // Tool rows: a chevron that turns down while the row is expanded.
                Text {
                  id: chevron
                  visible: row.isTool
                  width: Style.space(14)
                  height: label.contentHeight
                  y: label.y
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: root.note
                  text: "\u203a"
                  rotation: row.expanded ? 90 : 0

                  Behavior on rotation {
                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                  }
                }

                Text {
                  id: label
                  x: row.isTool ? chevron.width : row.padX
                  y: row.leadIn + row.padY + row.opticalShift
                  width: rows.width - x - row.padX
                  wrapMode: row.isTool ? Text.NoWrap : Text.Wrap
                  elide: row.isTool ? Text.ElideRight : Text.ElideNone
                  textFormat: Text.PlainText
                  lineHeightMode: Text.ProportionalHeight
                  lineHeight: 1.0
                  font.family: root.fontFamily
                  font.pixelSize: row.isTool ? Style.font.caption : Style.font.body
                  color: row.isTool ? root.note : Color.menu.text
                  visible: row.isTool
                  text: row.isAnswer ? ""
                    : row.isTool
                    ? (row.rowCount > 1 ? row.rowCount + " steps \u00b7 " : "") + row.rowText
                    : row.rowText
                }

                // Your messages and errors: selectable plain text.
                ChatText {
                  id: msg
                  visible: row.isYou || row.isError
                  x: label.x
                  y: label.y
                  width: label.width
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: Color.menu.text
                  opacity: 0.95
                  text: (row.isYou || row.isError) ? row.rowText : ""
                  onSelectedTextChanged: root.noteSelection(msg)
                  onClicked: root.chatClick(msg, row.rowText)
                }

                Column {
                  id: answer
                  visible: row.isAnswer
                  width: rows.width

                  Repeater {
                    model: row.segments

                    delegate: Item {
                      id: segment

                      required property var modelData

                      readonly property string kind: segment.modelData.kind
                      // A blank line in the answer shows as one empty line (as in the
                      // terminal); a plain line break gets normal line spacing.
                      readonly property int gap: segment.modelData.gap === 2
                        ? Math.round(metrics.height * row.leading) + row.trailing
                        : segment.modelData.gap === 1 ? row.trailing : 0

                      width: answer.width
                      height: segment.gap + (segment.kind === "code" ? box.height
                        : segment.kind === "hr" ? Style.space(6)
                        : prose.contentHeight - (segment.modelData.tail ? row.trailing : 0))

                      // Paragraphs, headings, lists and quotes: one selectable document.
                      ChatText {
                        id: prose
                        visible: segment.kind === "prose"
                        y: segment.gap
                        width: parent.width
                        textFormat: TextEdit.RichText
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        color: Color.menu.text
                        opacity: 0.95
                        text: segment.kind === "prose" ? segment.modelData.html : ""
                        onSelectedTextChanged: root.noteSelection(prose)
                        onLinkActivated: function(link) { root.openLink(link) }
                        onClicked: root.chatClick(prose, row.rowText)
                      }

                      Rectangle {
                        visible: segment.kind === "hr"
                        y: segment.gap + Style.space(3)
                        width: parent.width
                        height: 1
                        color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.15)
                      }

                      // Code and tables: monospace, whitespace kept, in a faint box.
                      Rectangle {
                        id: box
                        visible: segment.kind === "code"
                        y: segment.gap
                        width: parent.width
                        height: code.contentHeight + Style.space(8) * 2
                        radius: Style.cornerRadius
                        color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.06)
                        border.width: 1
                        border.color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.1)

                        HoverHandler {
                          id: codeHover
                        }

                        ChatText {
                          id: code
                          x: Style.space(10)
                          y: Style.space(8)
                          width: parent.width - Style.space(20)
                          wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                          textFormat: TextEdit.RichText
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          color: Color.menu.text
                          text: segment.kind === "code"
                            ? AskModel.highlightCode(segment.modelData.text, segment.modelData.lang, root.codePalette) : ""
                          onSelectedTextChanged: root.noteSelection(code)
                          onClicked: root.chatClick(code, segment.modelData.text)
                        }

                        // Copy just this block.
                        Rectangle {
                          id: codeCopy
                          property bool done: false
                          anchors.right: parent.right
                          anchors.top: parent.top
                          anchors.margins: Style.space(4)
                          width: codeCopyText.implicitWidth + Style.space(12)
                          height: codeCopyText.implicitHeight + Style.space(6)
                          radius: Style.cornerRadius
                          color: codeCopyArea.containsMouse ? Color.menu.selectedBackground : box.color
                          opacity: codeHover.hovered || codeCopy.done ? 1 : 0
                          visible: segment.kind === "code"

                          Behavior on opacity {
                            NumberAnimation { duration: 120 }
                          }

                          Text {
                            id: codeCopyText
                            anchors.centerIn: parent
                            text: codeCopy.done ? "Copied" : "Copy"
                            color: codeCopy.done ? Color.accent : root.note
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }

                          MouseArea {
                            id: codeCopyArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              root.copyText(segment.modelData.text)
                              codeCopy.done = true
                              codeCopyReset.restart()
                            }
                          }

                          Timer {
                            id: codeCopyReset
                            interval: 1200
                            onTriggered: codeCopy.done = false
                          }
                        }
                      }
                    }
                  }
                }

                HoverHandler {
                  id: hover
                  cursorShape: Qt.PointingHandCursor
                }

                // Tool rows expand instead (see the list's TapHandler).
                TapHandler {
                  id: rowTap
                  enabled: !row.isTool && !row.isApprove
                  onTapped: function(eventPoint) {
                    // A click on a code block copies just that block.
                    var text = row.rowText
                    if (row.isAnswer) {
                      var p = answer.mapFromItem(row, eventPoint.position.x, eventPoint.position.y)
                      var seg = answer.childAt(p.x, p.y)
                      if (seg && seg.kind === "code") text = seg.modelData.text
                    }
                    root.queueCopy(text)
                  }
                }

                Column {
                  id: approval
                  visible: row.isApprove
                  width: rows.width
                  spacing: Style.space(6)

                  readonly property bool waiting: row.isApprove && row.rowCount === 0

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: approval.waiting ? Color.accent
                      : row.rowCount === 2 ? Color.urgent : root.note
                    text: "\uf132  " + (approval.waiting
                        ? "Allow this?" + (row.approvalInfo.description ? " \u00b7 " + row.approvalInfo.description : "")
                        : (row.rowCount === 1 ? "Allowed"
                           : row.rowCount === 2 ? "Denied"
                           : row.rowCount === 3 ? "Allowed for this chat"
                           : "No longer needed") + " \u00b7 " + row.rowText)
                  }

                  Rectangle {
                    visible: approval.waiting
                    width: parent.width
                    height: approvalText.contentHeight + Style.space(7) * 2
                    radius: Style.cornerRadius
                    color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.06)
                    border.width: 1
                    border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5)

                    ChatText {
                      id: approvalText
                      x: Style.space(9)
                      y: Style.space(7)
                      width: parent.width - Style.space(18)
                      wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      color: Color.menu.text
                      text: row.isApprove
                        ? (row.approvalInfo.name === "Bash" ? "$ " : "") + (row.approvalInfo.input || row.rowText) : ""
                      onSelectedTextChanged: root.noteSelection(approvalText)
                    }
                  }

                  Row {
                    visible: approval.waiting
                    spacing: Style.space(4)

                    Button {
                      text: "Allow"
                      tooltipText: "Run it"
                      bordered: true
                      fontSize: Style.font.caption
                      foreground: Color.accent
                      horizontalPadding: Style.space(10)
                      verticalPadding: Style.space(3)
                      onClicked: root.decide(index, true, false)
                    }

                    Button {
                      text: "Always in this chat"
                      tooltipText: "Run it, and don't ask again in this chat"
                      bordered: true
                      fontSize: Style.font.caption
                      foreground: root.note
                      horizontalPadding: Style.space(10)
                      verticalPadding: Style.space(3)
                      onClicked: root.decide(index, true, true)
                    }

                    Button {
                      text: "Deny"
                      tooltipText: "Don't run it; Claude is told you said no"
                      bordered: true
                      fontSize: Style.font.caption
                      foreground: Color.urgent
                      horizontalPadding: Style.space(10)
                      verticalPadding: Style.space(3)
                      onClicked: root.decide(index, false, false)
                    }
                  }
                }

                // Expanded tool row: per step, "$ command" over its output.
                Column {
                  id: detail
                  visible: row.isTool && row.expanded
                  x: Style.space(14)
                  y: row.headerHeight + Style.space(4)
                  width: rows.width - x
                  spacing: Style.space(10)

                  Repeater {
                    model: row.steps

                    delegate: Column {
                      id: step

                      required property var modelData

                      readonly property bool running: !step.modelData.done && root.asking
                      readonly property string output: step.modelData.done ? step.modelData.output
                        : step.running ? "Running\u2026" : ""

                      width: detail.width
                      spacing: Style.space(4)

                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        color: root.note
                        text: step.modelData.name
                          + (step.modelData.description ? " \u00b7 " + step.modelData.description : "")
                      }

                      Rectangle {
                        width: parent.width
                        height: stepBody.height + Style.space(7) * 2
                        radius: Style.cornerRadius
                        color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.06)
                        border.width: 1
                        border.color: step.modelData.error ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.5)
                          : Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.1)

                        Column {
                          id: stepBody
                          x: Style.space(9)
                          y: Style.space(7)
                          width: parent.width - Style.space(18)
                          spacing: Style.space(6)

                          ChatText {
                            id: command
                            width: parent.width
                            visible: text !== ""
                            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            color: Color.menu.text
                            text: step.modelData.input
                              ? (step.modelData.name === "Bash" ? "$ " : "") + step.modelData.input : ""
                            onSelectedTextChanged: root.noteSelection(command)
                            onClicked: root.queueCollapse(command, row)
                          }

                          Rectangle {
                            visible: step.modelData.input !== "" && step.output !== ""
                            width: parent.width
                            height: 1
                            color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.1)
                          }

                          ChatText {
                            id: output
                            width: parent.width
                            visible: text !== ""
                            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            font.italic: step.running
                            color: step.modelData.error ? Color.urgent : root.note
                            text: step.output || (step.modelData.done ? "(no output)" : "")
                            onSelectedTextChanged: root.noteSelection(output)
                            onClicked: root.queueCollapse(output, row)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // Fades hint at more text above / below.
        Rectangle {
          anchors { left: list.left; right: list.right; top: list.top }
          height: Style.space(16)
          opacity: list.contentY > 1 ? 1 : 0

          gradient: Gradient {
            GradientStop { position: 0; color: card.color }
            GradientStop {
              position: 1
              color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0)
            }
          }

          Behavior on opacity {
            NumberAnimation { duration: 120 }
          }
        }

        Rectangle {
          anchors { left: list.left; right: list.right; bottom: list.bottom }
          height: Style.space(16)
          opacity: list.atYEnd ? 0 : 1

          gradient: Gradient {
            GradientStop {
              position: 0
              color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0)
            }
            GradientStop { position: 1; color: card.color }
          }

          Behavior on opacity {
            NumberAnimation { duration: 120 }
          }
        }

        // Scroll bar, in the strip kept clear of text: drag the thumb, or
        // click the track to jump there. It widens under the mouse.
        Item {
          id: scrollBar

          readonly property real scrollable: list.contentHeight - list.height
          readonly property bool hot: scrollArea.containsMouse || scrollArea.pressed

          anchors { right: list.right; top: list.top; bottom: list.bottom }
          width: Style.space(12)
          visible: scrollBar.scrollable > 1

          Rectangle {
            id: thumb

            anchors.right: parent.right
            width: scrollBar.hot ? Math.max(4, Style.space(6)) : Math.max(2, Style.space(2))
            radius: width / 2
            height: Math.max(Style.space(18), list.height * (list.height / list.contentHeight))
            y: (list.height - thumb.height) * Math.min(1, Math.max(0, list.contentY / Math.max(1, scrollBar.scrollable)))
            color: Color.menu.text
            opacity: scrollArea.pressed ? 0.5 : scrollBar.hot ? 0.35 : list.moving ? 0.4 : 0.16

            Behavior on width {
              NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }

            Behavior on opacity {
              NumberAnimation { duration: 200 }
            }
          }

          MouseArea {
            id: scrollArea

            // Where on the thumb the press landed, so dragging doesn't jump.
            property real grab: 0

            function scrollTo(mouseY) {
              var track = list.height - thumb.height
              if (track <= 0) return
              list.contentY = Math.max(0, Math.min(track, mouseY - scrollArea.grab)) / track * scrollBar.scrollable
            }

            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true

            onPressed: function(mouse) {
              root.followTail = false
              var onThumb = mouse.y >= thumb.y && mouse.y <= thumb.y + thumb.height
              scrollArea.grab = onThumb ? mouse.y - thumb.y : thumb.height / 2
              scrollArea.scrollTo(mouse.y)
            }
            onPositionChanged: function(mouse) {
              if (scrollArea.pressed) scrollArea.scrollTo(mouse.y)
            }
            onReleased: root.followTail = list.atYEnd
          }
        }
      }
    }

    // The input pill.
    BorderSurface {
      id: pill

      width: panel.surfaceWidth
      // One line: 76. Grows with Shift+Enter lines, up to about six, then the
      // text scrolls inside.
      height: Math.max(Style.space(76), Math.min(Math.ceil(promptField.contentHeight) + Style.space(52),
                                                 Style.space(76) + Math.round(promptMetrics.height * 5)))
      x: panel.surfaceX
      y: panel.pillY
      radius: Math.min(height / 2, Style.space(38))
      // Glass: a translucent tint the compositor blurs behind; the rim
      // brightens while you type.
      color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0.55)
      borderSpec: Border.none()
      padding: Style.space(4)
      scale: root.opened ? 1 : 0.96

      FontMetrics {
        id: promptMetrics
        font: promptField.font
      }

      Behavior on height {
        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
      }

      GlassSheen {
        radius: pill.radius
        strength: promptField.activeFocus ? 1.35 : 1.0

        Behavior on strength {
          NumberAnimation { duration: 160 }
        }
      }
      // Hidden while the help panel is open, so its text reads cleanly.
      opacity: root.opened && !root.helpOpen ? 1 : 0

      Behavior on y {
        enabled: !mover.active
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      Behavior on scale {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: {
          root.closeMenus()
          root.collapseTools()
          root.clearSelection()
          promptField.forceActiveFocus()
        }
      }

      // Drag the pill (and the card with it) anywhere; the spot is remembered.
      DragHandler {
        id: mover

        target: null
        cursorShape: Qt.SizeAllCursor

        property int fromX: 0
        property int fromY: 0

        onActiveChanged: {
          if (mover.active) {
            mover.fromX = root.dragX
            mover.fromY = root.dragY
          } else {
            root.savePosition()
          }
        }

        onActiveTranslationChanged: {
          if (!mover.active) return
          root.dragX = panel.clampX(mover.fromX + Math.round(mover.activeTranslation.x))
          root.dragY = panel.clampY(mover.fromY + Math.round(mover.activeTranslation.y))
        }
      }

      Row {
        id: pillRow
        anchors.fill: parent
        anchors.leftMargin: Style.space(20)
        anchors.rightMargin: Style.space(24)
        spacing: Style.space(14)

        readonly property int logoWidth: Style.space(44)
        readonly property bool showModel: !root.asking
        // Three 5px dots with 5px gaps while asking, else the model label
        // (its menu also holds the Detailed / Safe switches).
        readonly property int trailWidth: root.asking ? Style.space(25) : trailRow.implicitWidth

        // Agent logo; click for the agent menu.
        Item {
          id: logoMark
          property var candidates: root.logoCandidates()
          property string candidatesKey: candidates.join("\n")
          property int candidateIndex: 0
          onCandidatesKeyChanged: candidateIndex = 0
          width: pillRow.logoWidth
          height: parent.height

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(44)
            height: width
            radius: width / 2
            color: logoArea.containsMouse || root.pickerOpen ? Color.menu.selectedBackground : "transparent"

            Behavior on color {
              ColorAnimation { duration: 100 }
            }
          }

          Image {
            id: logoImage
            anchors.centerIn: parent
            width: Style.space(30)
            height: width
            source: logoMark.candidateIndex < logoMark.candidates.length ? logoMark.candidates[logoMark.candidateIndex] : ""
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectFit
            onStatusChanged: if (status === Image.Error && logoMark.candidateIndex < logoMark.candidates.length)
              Qt.callLater(function() { logoMark.candidateIndex++ })
          }

          Text {
            anchors.centerIn: parent
            visible: logoImage.status !== Image.Ready
            text: root.provider && root.provider.name ? root.provider.name.charAt(0) : "?"
            textFormat: Text.PlainText
            color: Color.menu.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          MouseArea {
            id: logoArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.agents.length > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
            enabled: !root.asking
            onClicked: {
              root.modelPickerOpen = false
              root.pickerOpen = !root.pickerOpen
              promptField.forceActiveFocus()
            }
          }
        }

        Item {
          width: parent.width - pillRow.logoWidth - pillRow.trailWidth
            - parent.spacing * (pillRow.trailWidth > 0 ? 2 : 1)
          height: parent.height

          // Multi-line: Shift+Enter adds a line, the pill grows up to about six
          // lines, then this scrolls (wheel / touchpad; mouse drags select).
          Flickable {
            id: promptFlick

            function ensureVisible(r) {
              if (promptFlick.contentY >= r.y) promptFlick.contentY = r.y
              else if (promptFlick.contentY + promptFlick.height <= r.y + r.height)
                promptFlick.contentY = r.y + r.height - promptFlick.height
            }

            anchors.fill: parent
            anchors.topMargin: Style.space(10)
            anchors.bottomMargin: Style.space(10)
            contentWidth: width
            contentHeight: promptField.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            acceptedButtons: Qt.NoButton

            TextEdit {
              id: promptField
              width: promptFlick.width
              height: Math.max(promptFlick.height, contentHeight)
              color: Color.menu.text
              selectionColor: Color.menu.selectedBackground
              selectedTextColor: Color.menu.selectedText
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              verticalAlignment: TextEdit.AlignVCenter
              textFormat: TextEdit.PlainText
              wrapMode: TextEdit.Wrap
              selectByMouse: true

              cursorDelegate: Rectangle {
                width: Math.max(1, Style.space(1))
                color: Color.accent
              }

              onCursorRectangleChanged: promptFlick.ensureVisible(cursorRectangle)

              onTextChanged: {
                // TextEdit has no maximumLength: trim anything past the limit.
                if (text.length > root.maxPrompt) {
                  var pos = cursorPosition
                  text = text.slice(0, root.maxPrompt)
                  cursorPosition = Math.min(pos, text.length)
                  return
                }
                root.promptText = AskModel.clipText(text, root.maxPrompt)
                root.recentIndex = -1
              }

              Keys.priority: Keys.BeforeItem

              Keys.onPressed: function(event) {
                var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                if (event.key === Qt.Key_Escape) {
                  if (root.menuOpen) root.closeMenus()
                  else root.dismiss()
                  event.accepted = true
                } else if (enter && (event.modifiers & Qt.ShiftModifier)) {
                  // Shift+Enter: a new line (Enter alone sends).
                  promptField.remove(promptField.selectionStart, promptField.selectionEnd)
                  promptField.insert(promptField.cursorPosition, "\n")
                  event.accepted = true
                } else if (enter && (event.modifiers & Qt.ControlModifier)) {
                  root.searchGoogle()
                  event.accepted = true
                } else if (enter) {
                  root.closeMenus()
                  if (!panel.chatting && root.recentIndex >= 0 && root.recentIndex < root.recentShown.length)
                    root.openRecent(root.recentShown[root.recentIndex])
                  else
                    root.submit()
                  event.accepted = true
                } else if ((event.key === Qt.Key_Up || event.key === Qt.Key_Down)
                           && (event.modifiers & Qt.ControlModifier)) {
                  root.recallPrompt(event.key === Qt.Key_Up ? -1 : 1)
                  event.accepted = true
                } else if ((event.key === Qt.Key_Up || event.key === Qt.Key_Down) && panel.showRecent) {
                  root.moveRecent(event.key === Qt.Key_Up ? -1 : 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier) && root.warmAgent) {
                  // Shift+Insert is how the clipboard manager (Super+Ctrl+V)
                  // pastes what you pick, so an older image attaches too.
                  root.pasteClipboard()
                  event.accepted = true
                } else if (event.modifiers & Qt.ControlModifier) {
                  if (event.key === Qt.Key_E) {
                    root.openTerminal()
                    event.accepted = true
                  } else if (event.key === Qt.Key_C && promptField.selectedText.length === 0) {
                    if (!root.copySelection()) root.stopRun()
                    event.accepted = true
                  } else if (event.key === Qt.Key_V && root.warmAgent) {
                    root.pasteClipboard()
                    event.accepted = true
                  } else if (event.key === Qt.Key_I) {
                  root.toggleTemp()
                  event.accepted = true
                } else if (event.key === Qt.Key_H) {
                    root.toggleHelp()
                    event.accepted = true
                  } else if (event.key === Qt.Key_D) {
                    if (!root.asking) root.setOption("detailed", !root.detailed)
                    event.accepted = true
                  } else if (event.key === Qt.Key_N) {
                    root.newChat()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Y) {
                    root.copyLast()
                    event.accepted = true
                  }
                } else if (event.key === Qt.Key_PageUp) {
                  root.followTail = false
                  list.contentY = Math.max(0, list.contentY - list.height * 0.8)
                  event.accepted = true
                } else if (event.key === Qt.Key_PageDown) {
                  list.contentY = Math.min(Math.max(0, list.contentHeight - list.height),
                                           list.contentY + list.height * 0.8)
                  root.followTail = list.atYEnd
                  event.accepted = true
                }
              }
            }
          }

          Text {
            anchors.fill: parent
            visible: promptField.text.length === 0
            text: root.tempChat
              ? (panel.chatting ? "Follow up (temporary)…" : "Temporary chat: nothing is saved")
              : (panel.chatting ? "Follow up…" : root.placeholder)
            color: Color.menu.text
            opacity: 0.44
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }
        }

        // Right end: the model while idle, thinking dots while answering.
        Item {
          width: pillRow.trailWidth
          height: parent.height

          Row {
            id: trailRow
            anchors.right: parent.right
            height: parent.height
            spacing: Style.space(2)
            visible: !root.asking

            Item {
              id: modelTag
              width: modelText.width
              height: parent.height
              visible: pillRow.showModel

              Text {
                id: modelText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, Style.space(180))
                // A red shield only while safe mode is off (commands run unasked).
                text: (root.safeMode ? "" : '<font color="' + String(Color.urgent) + '">\uf132</font>  ')
                  + AskModel.escapeHtml(root.modelShort) + " ▾"
                textFormat: Text.StyledText
                elide: Text.ElideLeft
                color: root.modelPickerOpen ? Color.accent : Color.menu.text
                opacity: modelArea.containsMouse || root.modelPickerOpen ? 1 : 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                Behavior on opacity {
                  NumberAnimation { duration: 100 }
                }
              }

              MouseArea {
                id: modelArea
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.pickerOpen = false
                  root.modelPickerOpen = !root.modelPickerOpen
                  promptField.forceActiveFocus()
                }
              }
            }
          }

          Row {
            id: dotsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)
            visible: root.asking

            Repeater {
              model: 3

              delegate: Rectangle {
                width: Style.space(5)
                height: width
                radius: width / 2
                color: Color.menu.text
                opacity: 0.25

                SequentialAnimation on opacity {
                  running: dotsRow.visible
                  loops: Animation.Infinite
                  PauseAnimation { duration: index * 160 }
                  NumberAnimation { to: 0.85; duration: 300; easing.type: Easing.OutCubic }
                  NumberAnimation { to: 0.25; duration: 300; easing.type: Easing.InCubic }
                  PauseAnimation { duration: 480 - index * 160 }
                }
              }
            }
          }
        }
      }
    }

    // Under the pill: what Enter / Ctrl+Enter do, then the chat actions.
    Item {
      id: hints

      x: pill.x + Style.space(12)
      y: pill.y + pill.height + Style.space(8)
      width: pill.width - Style.space(24)
      height: Style.space(24)
      // Hidden while the help panel is open, so its text reads cleanly.
      opacity: root.opened && !root.helpOpen ? 1 : 0
      enabled: !root.helpOpen

      // The key hints sit centred until chat actions appear on the right,
      // then slide over to the left.
      readonly property bool hasActions: actionsRow.width > 0

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      // Clicks between the buttons keep the overlay open.
      MouseArea {
        anchors.fill: parent
        onClicked: promptField.forceActiveFocus()
      }

      // What goes with the next message; click one to drop it.
      Row {
        id: attachRow
        x: -Style.space(7)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        visible: root.attachImage !== ""

        Button {
          text: "\u25a3 Image  \u00d7"
          tooltipText: "Goes with your next message \u2014 click to remove"
          selected: true
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.attachImage = ""
        }
      }

      Row {
        id: keysRow
        visible: !attachRow.visible
        x: hints.hasActions ? -Style.space(7) : Math.round((hints.width - keysRow.width) / 2)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Behavior on x {
          NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Button {
          text: "Ask " + (root.provider && root.provider.name ? root.provider.name : "AI") + " \u21b5"
          tooltipText: "Enter \u2014 send to " + (root.provider && root.provider.name ? root.provider.name : "the agent")
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: {
            root.closeMenus()
            root.submit()
          }
        }

        Button {
          text: "Search in browser ^\u21b5"
          tooltipText: "Ctrl+Enter \u2014 Google it in your default browser"
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.searchGoogle()
        }

        Button {
          text: "Temporary ^I"
          tooltipText: "Ctrl+I \u2014 a chat that isn't saved anywhere"
          selected: root.tempChat
          fontSize: Style.font.caption
          foreground: root.tempChat ? Color.accent : root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.toggleTemp()
        }

        Button {
          text: "Help ^H"
          tooltipText: "Ctrl+H \u2014 all shortcuts"
          selected: root.helpOpen
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.toggleHelp()
        }
      }

      Row {
        id: actionsRow
        anchors.right: parent.right
        anchors.rightMargin: -Style.space(7)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Button {
          text: "Terminal ^E"
          tooltipText: "Ctrl+E \u2014 continue this chat in the terminal"
          visible: root.currentSession !== "" && !root.asking && !root.tempChat
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.openTerminal()
        }

        Button {
          text: "Stop ^C"
          tooltipText: "Ctrl+C \u2014 stop the answer"
          visible: root.asking
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.stopRun()
        }

        Button {
          text: "Copy ^Y"
          tooltipText: "Ctrl+Y \u2014 copy the last answer (selecting or clicking text copies it too)"
          visible: root.lastAnswer !== ""
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.copyLast()
        }

        Button {
          text: "New ^N"
          tooltipText: "Ctrl+N \u2014 start a new chat"
          visible: panel.chatting
          fontSize: Style.font.caption
          foreground: root.note
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: root.newChat()
        }
      }
    }

    // Toast: a small glass pill in free space, never over the card or pill.
    // In a chat it sits under the hint bar (above the card if there's no room
    // there); with no chat open it sits above the pill, since recent chats fill
    // the space below. It pops in, holds for a moment and fades.
    Rectangle {
      id: toastPill

      readonly property bool shown: root.toastShown && root.opened
      readonly property int belowY: hints.y + hints.height + Style.space(8)
      readonly property int aboveY: (panel.chatting ? card.y : pill.y) - height - Style.space(10)
      readonly property bool roomBelow: toastPill.belowY + height <= panel.height - Style.space(8)

      width: toastLabel.implicitWidth + Style.space(32)
      height: toastLabel.implicitHeight + Style.space(14)
      x: pill.x + Math.round((pill.width - width) / 2)
      y: panel.chatting
        ? (toastPill.roomBelow ? toastPill.belowY : toastPill.aboveY)
        : (toastPill.aboveY >= Style.space(8) ? toastPill.aboveY : toastPill.belowY)
      radius: height / 2
      color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0.82)
      opacity: toastPill.shown ? 1 : 0
      scale: toastPill.shown ? 1 : 0.9
      visible: opacity > 0

      Behavior on opacity {
        NumberAnimation { duration: toastPill.shown ? 110 : 260 }
      }

      Behavior on scale {
        NumberAnimation { duration: 180; easing.type: Easing.OutBack }
      }

      GlassSheen {
        radius: toastPill.radius
        strength: 1.3
      }

      Text {
        id: toastLabel
        anchors.centerIn: parent
        text: root.toastText
        textFormat: Text.StyledText
        color: Color.menu.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // No chat open: your recent chats under the hint bar, with nothing behind
    // them. The list fades out at the bottom while more are below, and scrolls
    // with a faint accent scroll bar. Click one to go on with it; the \u00d7 on
    // hover takes it off this list.
    Item {
      id: recentPanel

      readonly property int listTop: hints.y + hints.height + Style.space(10)
      readonly property int rowHeight: Style.space(36)
      // Up to 8 rows, and never past the bottom of the screen.
      readonly property int listHeight: Math.min(recentColumn.implicitHeight, recentPanel.rowHeight * 8,
                                                 panel.height - recentPanel.listTop - recentHeader.height - Style.space(28))

      x: pill.x + Style.space(12)
      y: recentPanel.listTop
      width: pill.width - Style.space(24)
      height: recentHeader.height + Style.space(4) + recentPanel.listHeight
      visible: panel.showRecent && recentPanel.listHeight >= recentPanel.rowHeight
      // Hidden while the help panel is open, so its text reads cleanly.
      opacity: root.opened && !root.helpOpen ? 1 : 0
      enabled: !root.helpOpen

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      // Clicks between rows keep the overlay open.
      MouseArea {
        anchors.fill: parent
        onClicked: promptField.forceActiveFocus()
      }

      Connections {
        target: root
        function onRecentIndexChanged() {
          if (root.recentIndex < 0) return
          var top = root.recentIndex * recentPanel.rowHeight
          if (top < recentList.contentY) recentList.contentY = top
          else if (top + recentPanel.rowHeight > recentList.contentY + recentList.height)
            recentList.contentY = top + recentPanel.rowHeight - recentList.height
        }
      }

      // The scroll bar only shows while the mouse is over the list.
      HoverHandler {
        id: recentHover
      }

      Item {
        id: recentHeader
        width: parent.width - Style.space(12)
        height: Style.space(20)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          leftPadding: Style.space(10)
          text: root.promptText && !panel.chatting ? "Matching chats" : "Recent chats"
          color: root.subtle
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Clear the list (pinned chats stay). Asks for a second click.
        Text {
          id: clearLink
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: root.clearArmed ? "Clear all but pinned? Click again" : "Clear"
          color: root.clearArmed ? Color.urgent : root.subtle
          opacity: clearArea.containsMouse || root.clearArmed ? 1 : (recentHover.hovered ? 0.8 : 0)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          Behavior on opacity {
            NumberAnimation { duration: 120 }
          }

          MouseArea {
            id: clearArea
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.clearArmed) root.clearRecent()
              else {
                root.clearArmed = true
                clearDisarm.restart()
              }
            }
          }

          Timer {
            id: clearDisarm
            interval: 3000
            onTriggered: root.clearArmed = false
          }
        }
      }

      Item {
        id: recentView

        anchors.top: recentHeader.bottom
        anchors.topMargin: Style.space(4)
        width: parent.width
        height: recentPanel.listHeight

        // Fade the rows out at the bottom edge while there are more below.
        layer.enabled: !recentList.atYEnd
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: recentFade
          // Threshold 0.5 with spread 1 passes the mask's alpha straight
          // through (a soft gradient rather than a hard edge).
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }

        Flickable {
          id: recentList
          anchors.fill: parent
          contentHeight: recentColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: recentColumn
            // Leave the right edge to the scroll bar.
            width: recentList.width - Style.space(12)

            Repeater {
              model: root.recentShown

            delegate: Rectangle {
              id: recentRow

              required property var modelData
              required property int index

              readonly property bool picked: recentRow.index === root.recentIndex
              readonly property bool hot: recentArea.containsMouse || forgetArea.containsMouse
                || pinArea.containsMouse || recentRow.picked
              readonly property var candidates: root.logoCandidates(recentRow.modelData.agent)
              property int candidateIndex: 0

              width: recentColumn.width
              height: Style.space(36)
              radius: height / 2
              color: recentRow.hot ? Color.menu.selectedBackground : "transparent"

              Behavior on color {
                ColorAnimation { duration: 100 }
              }

              MouseArea {
                id: recentArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openRecent(recentRow.modelData)
              }

              // The chat's agent: its logo (or first letter when there is none).
              Image {
                id: recentLogo
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(16)
                height: width
                source: recentRow.candidateIndex < recentRow.candidates.length
                  ? recentRow.candidates[recentRow.candidateIndex] : ""
                sourceSize.width: width * 2
                sourceSize.height: height * 2
                fillMode: Image.PreserveAspectFit
                opacity: recentRow.hot ? 1 : 0.85
                onStatusChanged: if (status === Image.Error && recentRow.candidateIndex < recentRow.candidates.length)
                  Qt.callLater(function() { recentRow.candidateIndex++ })
              }

              Text {
                anchors.centerIn: recentLogo
                visible: recentLogo.status !== Image.Ready
                text: AskModel.providerFor(recentRow.modelData.agent).name.charAt(0)
                textFormat: Text.PlainText
                color: root.subtle
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                anchors.left: recentLogo.right
                anchors.leftMargin: Style.space(10)
                anchors.right: recentPin.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: recentRow.modelData.title
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.menu.text
                opacity: recentRow.hot ? 1 : 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              // Pin: keeps the chat at the top (and through Clear).
              Text {
                id: recentPin
                anchors.right: recentMeta.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf08d"
                color: recentRow.modelData.pinned ? Color.accent : root.subtle
                opacity: recentRow.modelData.pinned || recentRow.hot ? 1 : 0
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: pinArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.togglePin(recentRow.modelData)
                }
              }

              // "Claude \u00b7 2h"
              Text {
                id: recentMeta
                anchors.right: recentForget.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: (recentRow.modelData.agent ? AskModel.providerFor(recentRow.modelData.agent).name + " \u00b7 " : "")
                  + AskModel.timeAgo(recentRow.modelData.updated, root.recentNow)
                color: root.subtle
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: recentForget
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "\u00d7"
                color: forgetArea.containsMouse ? Color.urgent : root.subtle
                opacity: recentRow.hot ? 1 : 0
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: forgetArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.forgetRecent(recentRow.modelData)
                }
              }
            }
            }
          }
        }
      }

      // Opaque at the top, clear at the bottom: the fade's mask.
      Item {
        id: recentFade
        anchors.fill: recentView
        visible: false
        layer.enabled: true

        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0; color: "white" }
            GradientStop {
              position: Math.max(0, 1 - Style.space(72) / Math.max(1, recentFade.height))
              color: "white"
            }
            GradientStop { position: 1; color: "transparent" }
          }
        }
      }

      // Scroll bar: thin and faintly accent-coloured, shown while the mouse is
      // over the list; drag it or click the track.
      Item {
        id: recentScroll

        readonly property real scrollable: recentList.contentHeight - recentList.height
        readonly property bool hot: recentScrollArea.containsMouse || recentScrollArea.pressed

        anchors { right: recentView.right; top: recentView.top; bottom: recentView.bottom }
        width: Style.space(10)
        visible: recentScroll.scrollable > 1

        Rectangle {
          id: recentThumb

          anchors.right: parent.right
          width: recentScroll.hot ? Math.max(3, Style.space(4)) : Math.max(2, Style.space(2))
          radius: width / 2
          height: Math.max(Style.space(18), recentList.height * (recentList.height / recentList.contentHeight))
          y: (recentList.height - recentThumb.height)
            * Math.min(1, Math.max(0, recentList.contentY / Math.max(1, recentScroll.scrollable)))
          color: Color.accent
          opacity: recentScrollArea.pressed ? 0.6 : recentScroll.hot ? 0.45
            : (recentHover.hovered || recentList.moving) ? 0.22 : 0

          Behavior on width {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
          }

          Behavior on opacity {
            NumberAnimation { duration: 200 }
          }
        }

        MouseArea {
          id: recentScrollArea

          property real grab: 0

          function scrollTo(mouseY) {
            var track = recentList.height - recentThumb.height
            if (track <= 0) return
            recentList.contentY = Math.max(0, Math.min(track, mouseY - recentScrollArea.grab)) / track
              * recentScroll.scrollable
          }

          anchors.fill: parent
          hoverEnabled: true
          preventStealing: true

          onPressed: function(mouse) {
            var onThumb = mouse.y >= recentThumb.y && mouse.y <= recentThumb.y + recentThumb.height
            recentScrollArea.grab = onThumb ? mouse.y - recentThumb.y : recentThumb.height / 2
            recentScrollArea.scrollTo(mouse.y)
          }
          onPositionChanged: function(mouse) {
            if (recentScrollArea.pressed) recentScrollArea.scrollTo(mouse.y)
          }
        }
      }
    }

    // Agent menu: pops up above the pill's left end.
    BorderSurface {
      id: agentMenu

      readonly property bool shown: root.pickerOpen && root.agents.length > 0

      width: Style.space(230)
      height: agentMenu.contentTopInset + agentColumn.implicitHeight + agentMenu.contentBottomInset
      x: pill.x + Style.space(6)
      y: pill.y - panel.gap - height
      radius: Style.space(18)
      color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0.93)
      borderSpec: Border.none()
      padding: Style.space(6)
      transformOrigin: Item.BottomLeft
      opacity: agentMenu.shown ? 1 : 0
      scale: agentMenu.shown ? 1 : 0.96
      visible: opacity > 0

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      Behavior on scale {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      GlassSheen {
        radius: agentMenu.radius
      }

      MouseArea { anchors.fill: parent }

      Column {
        id: agentColumn
        x: agentMenu.contentLeftInset
        y: agentMenu.contentTopInset
        width: agentMenu.width - agentMenu.contentLeftInset - agentMenu.contentRightInset

        Repeater {
          model: root.agents

          delegate: Rectangle {
            id: agentRow
            readonly property bool current: modelData.id === root.agentId
            property var candidates: root.logoCandidates(modelData.id)
            property int candidateIndex: 0

            width: agentColumn.width
            height: Style.space(40)
            radius: height / 2
            color: agentRowArea.containsMouse ? Color.menu.selectedBackground : "transparent"

            Behavior on color {
              ColorAnimation { duration: 100 }
            }

            Image {
              id: agentRowLogo
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              height: width
              source: agentRow.candidateIndex < agentRow.candidates.length ? agentRow.candidates[agentRow.candidateIndex] : ""
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              fillMode: Image.PreserveAspectFit
              onStatusChanged: if (status === Image.Error && agentRow.candidateIndex < agentRow.candidates.length)
                Qt.callLater(function() { agentRow.candidateIndex++ })
            }

            Text {
              anchors.centerIn: agentRowLogo
              visible: agentRowLogo.status !== Image.Ready
              text: modelData.name.charAt(0)
              textFormat: Text.PlainText
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              anchors.left: agentRowLogo.right
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.name
              textFormat: Text.PlainText
              color: Color.menu.text
              opacity: agentRow.current ? 1 : 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              visible: agentRow.current
              text: "✓"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: agentRowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectAgent(modelData.id)
            }
          }
        }
      }
    }

    // Model menu: pops up above the pill's right end. Models (when the agent
    // has more than one), then the Detailed / Safe switches.
    BorderSurface {
      id: modelMenu

      readonly property bool shown: root.modelPickerOpen
      readonly property int maxHeight: Math.max(Style.space(120), pill.y - panel.gap - Style.space(16))

      width: Style.space(300)
      height: Math.min(modelMenu.contentTopInset + modelColumn.implicitHeight + modelMenu.contentBottomInset,
                       modelMenu.maxHeight)
      x: pill.x + pill.width - width - Style.space(6)
      y: pill.y - panel.gap - height
      radius: Style.space(18)
      color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0.93)
      borderSpec: Border.none()
      padding: Style.space(6)
      transformOrigin: Item.BottomRight
      opacity: modelMenu.shown ? 1 : 0
      scale: modelMenu.shown ? 1 : 0.96
      visible: opacity > 0

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      Behavior on scale {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      GlassSheen {
        radius: modelMenu.radius
      }

      MouseArea { anchors.fill: parent }

      Flickable {
        x: modelMenu.contentLeftInset
        y: modelMenu.contentTopInset
        width: modelMenu.width - modelMenu.contentLeftInset - modelMenu.contentRightInset
        height: modelMenu.height - modelMenu.contentTopInset - modelMenu.contentBottomInset
        contentHeight: modelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: modelColumn
          width: parent.width

          Repeater {
            model: root.models.length > 1 ? root.models : []

            delegate: Rectangle {
              id: modelRow
              readonly property bool current: modelData.id === root.modelId

              width: modelColumn.width
              height: Style.space(36)
              radius: height / 2
              color: modelRowArea.containsMouse ? Color.menu.selectedBackground : "transparent"

              Behavior on color {
                ColorAnimation { duration: 100 }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(14)
                anchors.right: modelCheck.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Color.menu.text
                opacity: modelRow.current ? 1 : 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                id: modelCheck
                anchors.right: parent.right
                anchors.rightMargin: Style.space(14)
                anchors.verticalCenter: parent.verticalCenter
                text: modelRow.current ? "✓" : ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: modelRowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectModel(modelData.id)
              }
            }
          }

          Item {
            width: modelColumn.width
            height: Style.space(13)
            visible: root.models.length > 1

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              x: Style.space(14)
              width: parent.width - Style.space(28)
              height: 1
              color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.12)
            }
          }

          SettingRow {
            width: modelColumn.width
            label: "Detailed answers"
            hint: "Ctrl+D"
            checked: root.detailed
            onToggled: root.setOption("detailed", !root.detailed)
          }

          SettingRow {
            width: modelColumn.width
            label: "Safe mode"
            hint: "asks before commands"
            checked: root.safeMode
            onToggled: root.setOption("safeMode", !root.safeMode)
          }
        }
      }
    }

    // Help (Ctrl+H): shortcuts by area, centred over everything; scrolls
    // only on a very short screen. Esc, Ctrl+H or a click outside closes it.
    BorderSurface {
      id: helpPanel

      readonly property int keyWidth: Style.space(128)

      width: pill.width
      height: Math.min(helpPanel.contentTopInset + helpHeader.height + Style.space(10)
                         + helpColumn.implicitHeight + helpPanel.contentBottomInset,
                       panel.height - Style.space(48))
      x: pill.x
      y: Math.round((panel.height - height) / 2)
      radius: Style.space(20)
      color: Qt.rgba(Color.menu.background.r, Color.menu.background.g, Color.menu.background.b, 0.82)
      borderSpec: Border.none()
      padding: Style.space(16)
      transformOrigin: Item.Center
      opacity: root.helpOpen && root.opened ? 1 : 0
      scale: root.helpOpen ? 1 : 0.97
      visible: opacity > 0

      Behavior on opacity {
        NumberAnimation { duration: 100 }
      }

      Behavior on scale {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      GlassSheen {
        radius: helpPanel.radius
      }

      MouseArea { anchors.fill: parent }

      Item {
        id: helpHeader
        x: helpPanel.contentLeftInset
        y: helpPanel.contentTopInset
        width: helpPanel.width - helpPanel.contentLeftInset - helpPanel.contentRightInset
        height: Style.space(20)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Shortcuts"
          color: Color.menu.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Esc to close"
          color: root.subtle
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Flickable {
        x: helpPanel.contentLeftInset
        y: helpHeader.y + helpHeader.height + Style.space(10)
        width: helpPanel.width - helpPanel.contentLeftInset - helpPanel.contentRightInset
        height: helpPanel.height - y - helpPanel.contentBottomInset
        contentHeight: helpColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: helpColumn
          width: parent.width
          spacing: Style.space(12)

          Repeater {
            model: root.helpSections

            delegate: Column {
              id: helpSection

              required property var modelData

              width: helpColumn.width
              spacing: Style.space(4)

              Text {
                visible: helpSection.modelData.title !== ""
                text: helpSection.modelData.title
                color: root.subtle
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                bottomPadding: Style.space(2)
              }

              Repeater {
                model: helpSection.modelData.items

                delegate: Item {
                  id: helpItem

                  required property var modelData

                  width: helpSection.width
                  height: Math.max(helpKey.implicitHeight, helpText.contentHeight)

                  Text {
                    id: helpKey
                    width: helpPanel.keyWidth
                    text: helpItem.modelData[0]
                    color: Color.accent
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: helpText
                    x: helpPanel.keyWidth + Style.space(12)
                    width: parent.width - x
                    text: helpItem.modelData[1]
                    wrapMode: Text.Wrap
                    color: Color.menu.text
                    opacity: 0.9
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
