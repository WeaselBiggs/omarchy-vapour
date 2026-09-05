import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// The data side of the Steam panel. All extraction lives in bin/collect, which
// writes one JSON record to the state directory; this file only runs it on a
// timer, watches the record for changes, and keeps an eye on which Steam games
// currently have a window open.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/steam"
  readonly property string recordPath: stateDir + "/playtime.json"
  // The collector ships inside the plugin folder so a git checkout is the whole install.
  readonly property string collectorPath: String(Qt.resolvedUrl("bin/collect")).replace(/^file:\/\//, "")

  // ---------------------------------------------------------------- record

  property var record: null
  property string collectorError: ""

  readonly property var games: record && Array.isArray(record.games) ? record.games : []
  readonly property var days: record && Array.isArray(record.days) ? record.days : []
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
      console.warn("steam", "Ignoring bad playtime record", root.recordPath, e)
      root.record = null
    }
  }

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
        if (message !== "") console.warn("steam", message)
      }
    }
  }

  function collectorCommand() {
    var command = [root.collectorPath]
    command.push("--week-mode", String(setting("weekMode", "Rolling 7 days")).toLowerCase().indexOf("monday") >= 0 ? "monday" : "rolling")
    command.push("--min-minutes", String(Math.max(0, numberValue(setting("minMinutes", 5)))))
    if (setting("lookupNames", true) === false) command.push("--no-names")
    if (setting("hltbEnabled", true) === false) command.push("--no-hltb")
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

  // Hyprland already knows when a game is up: Steam titles map to a window
  // class of steam_app_<appid>, so no Steam API is involved in the "playing"
  // light. Toplevels are event-driven; the slow timer only catches XWayland
  // windows whose class arrives after the insert.
  property var runningAppIds: []

  function rescanRunning() {
    var ids = []
    try {
      var values = ToplevelManager.toplevels.values
      for (var i = 0; i < values.length; i++) {
        var match = String(values[i].appId || "").match(/^steam_app_(\d+)$/)
        if (match) ids.push(Number(match[1]))
      }
    } catch (e) {
      ids = []
    }
    ids.sort()
    if (JSON.stringify(ids) === JSON.stringify(runningAppIds)) return
    var stopped = runningAppIds.length > ids.length
    runningAppIds = ids
    if (stopped) settleRefresh.restart()
  }

  function isRunning(appId) {
    return runningAppIds.indexOf(Number(appId)) >= 0
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

  function playCommand(appId) {
    return "uwsm-app -- steam steam://rungameid/" + Number(appId)
  }

  function steamCommand() {
    return "omarchy-launch-or-focus steam 'uwsm-app -- steam'"
  }

  // ---------------------------------------------------------------- helpers

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
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
