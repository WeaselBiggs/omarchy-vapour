import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The data side of the Vapour panel. All extraction lives in bin/collect, which
// writes one JSON record to the state directory; this file runs it on a timer,
// watches the record for changes, and keeps an eye on which games currently
// have a window open. For stores that keep no playtime of their own, that
// watching *is* the playtime: every change is handed to bin/sessions, which
// keeps the ledger the collector folds in.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/vapour"
  readonly property string recordPath: stateDir + "/playtime.json"
  // The scripts ship inside the plugin folder so a git checkout is the whole install.
  readonly property string binDir: String(Qt.resolvedUrl("bin")).replace(/^file:\/\//, "")
  readonly property string collectorPath: binDir + "/collect"
  readonly property string sessionsPath: binDir + "/sessions"

  // ---------------------------------------------------------------- record

  property var record: null
  property string collectorError: ""

  readonly property var games: record && Array.isArray(record.games) ? record.games : []
  readonly property var days: record && Array.isArray(record.days) ? record.days : []
  readonly property var stores: record && Array.isArray(record.stores) ? record.stores : []
  // Games the collector wants timed: [{ id, classes: ["diablo iv.exe", ...] }].
  readonly property var watch: record && Array.isArray(record.watch) ? record.watch : []
  readonly property int weekMinutes: record ? numberValue(record.weekMinutes) : 0
  readonly property string weekSource: record ? String(record.weekSource || "none") : "none"
  readonly property string weekMode: record ? String(record.weekMode || "rolling") : "rolling"
  readonly property string baselineDate: record ? String(record.baselineDate || "") : ""
  readonly property int historyDays: record ? numberValue(record.historyDays) : 0
  readonly property bool fullWeek: !!record && record.fullWeek === true
  readonly property double updatedAtMs: record ? Number(record.updatedAtMs || 0) : 0
  readonly property string errorText: record && String(record.error || "") !== "" ? String(record.error) : collectorError
  readonly property bool hasDayHistory: {
    for (var i = 0; i < days.length; i++)
      if (days[i] && days[i].minutes !== null && days[i].minutes !== undefined) return true
    return false
  }

  FileView {
    id: recordFile
    path: root.recordPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.record = null
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.record = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("vapour", "Ignoring bad playtime record", root.recordPath, e)
      root.record = null
    }
  }

  // A fresh record may carry a new watch table; look again with it.
  onWatchChanged: rescanRunning()

  // --------------------------------------------------------------- refresh

  readonly property int refreshIntervalSec: Math.max(30, numberValue(setting("refreshIntervalSec", 900)))
  property bool refreshQueued: false

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Steam writes localconfig.vdf a little after a game exits; give it a moment
  // before reading the session that just ended.
  Timer {
    id: settleRefresh
    interval: 20000
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: collector
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) root.collectorError = "Collector exited with status " + exitCode
      // The FileView watch normally catches the write; reload anyway in case
      // the record was replaced by a rename it did not observe.
      recordFile.reload()
      if (root.refreshQueued) {
        root.refreshQueued = false
        root.refresh()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = text.trim()
        if (message !== "") console.warn("vapour", message)
      }
    }
  }

  function collectorCommand() {
    var command = [root.collectorPath]
    command.push("--week-mode", String(setting("weekMode", "Rolling 7 days")).toLowerCase().indexOf("monday") >= 0 ? "monday" : "rolling")
    command.push("--min-minutes", String(Math.max(0, numberValue(setting("minMinutes", 5)))))
    if (!boolSetting("lookupNames", true)) command.push("--no-names")
    if (!boolSetting("hltbEnabled", true)) command.push("--no-hltb")
    return command
  }

  function refresh() {
    if (collector.running) {
      refreshQueued = true
      return
    }
    collectorError = ""
    collector.command = collectorCommand()
    collector.running = true
  }

  onSettingsChanged: refresh()

  // ----------------------------------------------------------- running games

  // Hyprland already knows when a game is up. Steam titles map to a window
  // class of steam_app_<appid>; everything else is a Wine window whose class
  // is the executable's name, matched against the collector's watch table.
  // Toplevels are event-driven; the slow timer only catches XWayland windows
  // whose class arrives after the insert.
  property var runningIds: []
  // The subset Vapour times itself (everything that is not Steam's).
  property var runningWatched: []
  property bool sessionsSynced: false

  function watchedIdFor(windowClass) {
    var cls = String(windowClass || "").toLowerCase()
    if (cls === "") return ""
    for (var i = 0; i < watch.length; i++) {
      var classes = watch[i] && Array.isArray(watch[i].classes) ? watch[i].classes : []
      for (var j = 0; j < classes.length; j++)
        if (String(classes[j]).toLowerCase() === cls) return String(watch[i].id)
    }
    return ""
  }

  function rescanRunning() {
    var ids = []
    var watched = []
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var cls = String(values[i].appId || "")
        var match = cls.match(/^steam_app_(\d+)$/)
        var id = match ? "steam:" + match[1] : watchedIdFor(cls)
        if (id === "" || ids.indexOf(id) >= 0) continue
        ids.push(id)
        if (!match) watched.push(id)
      }
    } catch (e) {
      ids = []
      watched = []
    }
    ids.sort()
    watched.sort()
    var watchedChanged = JSON.stringify(watched) !== JSON.stringify(runningWatched)
    if (JSON.stringify(ids) !== JSON.stringify(runningIds)) {
      var steamBefore = runningIds.length - runningWatched.length
      var steamNow = ids.length - watched.length
      runningIds = ids
      runningWatched = watched
      if (steamNow < steamBefore) settleRefresh.restart()
    }
    // The first sync after the record arrives also closes sessions a dead
    // shell left open; before the record there is no watch table to trust.
    if (record && (watchedChanged || !sessionsSynced)) syncSessions()
  }

  function isRunning(id) {
    return runningIds.indexOf(String(id)) >= 0
  }

  // ---- the ledger

  property var sessionsQueued: null

  Process {
    id: sessionSync
    running: false
    property bool closedSomething: false
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("vapour", "sessions sync exited with status " + exitCode)
      root.sessionsSynced = true
      if (root.sessionsQueued !== null) {
        var ids = root.sessionsQueued
        root.sessionsQueued = null
        root.runSessionSync(ids)
      } else if (closedSomething) {
        closedSomething = false
        root.refresh()
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.indexOf("closed ") >= 0) sessionSync.closedSomething = true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = text.trim()
        if (message !== "") console.warn("vapour", message)
      }
    }
  }

  function runSessionSync(ids) {
    sessionSync.command = [root.sessionsPath, "sync"].concat(ids)
    sessionSync.running = true
  }

  function syncSessions() {
    if (sessionSync.running) {
      sessionsQueued = runningWatched.slice()
      return
    }
    runSessionSync(runningWatched.slice())
  }

  // Heartbeat while a watched game is up, so a shell that dies mid-session
  // still has the time up to the last minute on record.
  Timer {
    interval: 60000
    running: root.runningWatched.length > 0
    repeat: true
    onTriggered: root.syncSessions()
  }

  Connections {
    target: ToplevelManager.toplevels
    function onObjectInsertedPost(object, index) { root.rescanRunning() }
    function onObjectRemovedPost(object, index) { root.rescanRunning() }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: root.rescanRunning()
  }

  Component.onCompleted: rescanRunning()

  // ---------------------------------------------------------------- actions

  // Each game carries its own launch line from the collector: a Steam URI for
  // Steam, the Battle.net launcher with a product code for Blizzard, whatever
  // games.json says for the rest.
  function playCommand(game) {
    return game && game.play ? String(game.play) : ""
  }

  function steamCommand() {
    return "omarchy-launch-or-focus steam 'uwsm-app -- steam'"
  }

  // ---------------------------------------------------------------- helpers

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Booleans may arrive as strings: `omarchy bar set <id> <key> true` without
  // --json stores "true". Accept the usual spellings either way.
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    if (typeof value === "number") return value !== 0
    if (typeof value === "string") {
      var s = value.trim().toLowerCase()
      if (s === "true" || s === "1" || s === "yes" || s === "on") return true
      if (s === "false" || s === "0" || s === "no" || s === "off" || s === "") return false
    }
    return fallback
  }

  function numberValue(value) {
    var n = Number(value || 0)
    return isFinite(n) ? Math.round(n) : 0
  }

  function formatMinutes(minutes) {
    var m = numberValue(minutes)
    if (m <= 0) return "0m"
    var hours = Math.floor(m / 60)
    var rest = m % 60
    if (hours === 0) return rest + "m"
    if (rest === 0) return hours + "h"
    return hours + "h " + (rest < 10 ? "0" : "") + rest + "m"
  }

  // Hours with one decimal, for the how-long-to-beat comparison where minutes
  // would be false precision.
  function formatHours(hours) {
    var h = Number(hours)
    if (!isFinite(h) || h <= 0) return "—"
    return (Math.round(h * 10) / 10) + "h"
  }

  function formatAgo(ms, nowMs) {
    if (!(ms > 0)) return ""
    var delta = Math.max(0, nowMs - ms)
    var minutes = Math.floor(delta / 60000)
    if (minutes < 1) return "just now"
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    return Math.floor(hours / 24) + "d ago"
  }

  function formatLastPlayed(unixSeconds, nowMs) {
    var seconds = Number(unixSeconds)
    if (!(seconds > 0)) return "never"
    var then = new Date(seconds * 1000)
    var now = new Date(nowMs)
    var startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var dayMs = 24 * 3600 * 1000
    var daysAgo = Math.floor((startOfToday - then.getTime()) / dayMs) + 1
    if (then.getTime() >= startOfToday) return "today"
    if (daysAgo === 1) return "yesterday"
    if (daysAgo < 7) return daysAgo + " days ago"
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var text = then.getDate() + " " + months[then.getMonth()]
    if (then.getFullYear() !== now.getFullYear()) text += " " + then.getFullYear()
    return text
  }
}
