import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Vapour: Steam playtime in the bar, one icon and one panel. Lifted from the layout
// of omarchy.agents — hero, section headers, bars-behind-rows — with the
// numbers coming from bin/collect via Main.qml instead of usage collectors.
Panel {
  id: root
  moduleName: "dan.vapour"
  ipcTarget: "dan.vapour"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The panel's hero wears the Steam mark. The bar does not: Steam's own tray
  // icon already sits on that line, and two Steam badges side by side invite
  // confusion — so the bar shows a steaming cup instead (Steam → steam).
  readonly property string glyph: "󰓓"
  readonly property string barGlyph: "\uef59"  // fa-mug_hot: a filled mug that is visibly steaming

  readonly property var games: steam.games
  readonly property bool playing: steam.runningAppIds.length > 0

  // The cursor and the unfolded row follow the game, not its slot: a refresh
  // that reorders the list under an open panel must not swap what you're reading.
  property int cursorAppId: 0
  property int expandedAppId: 0
  property bool cursorActive: false

  readonly property int cursorIndex: indexOfApp(cursorAppId)
  readonly property var cursorGame: cursorIndex >= 0 ? games[cursorIndex] : null

  // "Updated 6m ago" and "last played today" read this instead of Date.now()
  // so the panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function indexOfApp(appId) {
    for (var i = 0; i < games.length; i++)
      if (Number(games[i].appId) === Number(appId)) return i
    return -1
  }

  function moveCursor(delta) {
    if (games.length === 0) return
    var index = cursorIndex < 0 ? (delta > 0 ? -1 : 0) : cursorIndex
    index = clamp(index + delta, 0, games.length - 1)
    cursorActive = true
    cursorAppId = Number(games[index].appId)
    Qt.callLater(ensureCursorVisible)
  }

  function toggleExpanded(appId) {
    var id = Number(appId)
    expandedAppId = expandedAppId === id ? 0 : id
  }

  function play(appId) {
    var id = Number(appId)
    if (!(id > 0)) return
    if (root.bar) root.bar.run(steam.playCommand(id))
    root.close()
  }

  function launchSteam() {
    if (root.bar) root.bar.run(steam.steamCommand())
    root.close()
  }

  function refreshNow() {
    steam.refresh()
    steam.rescanRunning()
  }

  // Keep the keyboard cursor's row inside the scrolled viewport.
  function ensureCursorVisible() {
    if (!panelFlick || cursorIndex < 0) return
    var row = gamesRepeater.itemAt(cursorIndex)
    if (!row) return
    var top = gamesSection.y + gamesList.y + row.y
    var bottom = top + row.height
    if (top < panelFlick.contentY) panelFlick.contentY = Math.max(0, top - Style.space(8))
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = clamp(bottom - panelFlick.height + Style.space(8), 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
  }

  // ---------------------------------------------------------------- content

  function heroDetail() {
    return steam.weekMinutes > 0 ? steam.formatMinutes(steam.weekMinutes) : ""
  }

  // Leads with "Steam" because the title no longer says it.
  function heroMeta() {
    var parts = ["Steam"]
    if (steam.weekSource === "twoWeeks") parts.push("Last 2 weeks")
    else if (steam.weekMode === "monday") parts.push("Since Monday")
    else parts.push("This week")
    parts.push(games.length + (games.length === 1 ? " game" : " games"))
    // Just the age, no "Updated": with "Steam" up front the line is tight.
    if (root.playing) parts.push("Playing now")
    else if (steam.updatedAtMs > 0) parts.push(steam.formatAgo(steam.updatedAtMs, root.nowMs))
    return parts.join(" · ")
  }

  // Only speaks up while the week is still being assembled from snapshots.
  function footerText() {
    if (steam.weekSource === "twoWeeks")
      return "Showing Steam's two-week totals — daily history starts today"
    if (steam.weekSource === "snapshots" && !steam.fullWeek) {
      var remaining = Math.max(1, 7 - steam.historyDays)
      return "History since " + steam.baselineDate + " · full week in " + remaining + (remaining === 1 ? " day" : " days")
    }
    return ""
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayPeak() {
    var peak = 0
    for (var i = 0; i < steam.days.length; i++) peak = Math.max(peak, Number(steam.days[i].minutes || 0))
    return Math.max(1, peak)
  }

  function weekPeak() {
    return games.length > 0 ? Math.max(1, Number(games[0].weekMinutes || 0)) : 1
  }

  function gameTooltip(game) {
    if (!game) return ""
    var text = steam.formatMinutes(game.weekMinutes) + " this week · " + steam.formatMinutes(game.totalMinutes) + " total"
    if (steam.isRunning(game.appId)) text += " · playing now"
    return text
  }

  // How far through the game you are, against HowLongToBeat's main-story
  // figure. Past the main story the meter measures the road to 100% instead.
  function progress(game) {
    var hltb = game ? game.hltb : null
    if (!hltb) return null
    var played = Number(game.totalMinutes || 0) / 60
    var main = Number(hltb.main || 0)
    var completionist = Number(hltb.completionist || 0)
    if (main > 0 && played < main)
      return { ratio: played / main, text: "~" + steam.formatHours(main - played) + " left in the main story" }
    if (completionist > 0 && played < completionist) {
      var percent = Math.round(played / completionist * 100) + "% of the way to completionist"
      // Some games only ever get a completionist figure; there is no main
      // story to have finished.
      return { ratio: played / completionist, text: main > 0 ? "Main story done · " + percent : percent }
    }
    if (main > 0 || completionist > 0)
      return { ratio: 1, text: "Beyond every HowLongToBeat estimate" }
    return null
  }

  function hltbLine(hltb) {
    if (!hltb) return ""
    var parts = []
    if (Number(hltb.main) > 0) parts.push("Main " + steam.formatHours(hltb.main))
    if (Number(hltb.extra) > 0) parts.push("Main + Extra " + steam.formatHours(hltb.extra))
    if (Number(hltb.completionist) > 0) parts.push("100% " + steam.formatHours(hltb.completionist))
    if (parts.length === 0 && Number(hltb.allStyles) > 0) parts.push("All styles " + steam.formatHours(hltb.allStyles))
    return parts.join(" · ")
  }

  // What the rundown says under HOW LONG TO BEAT when there are no figures.
  // The lookup runs in the background after each refresh, so "pending" is a
  // real state the panel can be caught in, not a failure.
  function hltbStatusText(game) {
    var status = game ? String(game.hltbStatus || "") : ""
    if (status === "pending") return "Looking up on HowLongToBeat…"
    if (status === "nodata") return "On HowLongToBeat, but nobody has submitted a time yet"
    if (status === "missing") return "Not found on HowLongToBeat"
    if (status === "error") return "HowLongToBeat unavailable — will retry"
    return "Length unknown"
  }

  // The matched title, only when it differs from Steam's in more than case
  // and trademark marks — a wrong match is the failure mode worth making
  // visible, "STAR WARS" against "Star Wars" is not.
  function looseTitle(text) {
    return String(text || "").toLowerCase().replace(/[\u2122\u00ae\u00a9]/g, "")
      .replace(/[^a-z0-9]+/g, " ").trim()
  }

  function hltbMatchNote(game) {
    if (!game || !game.hltb || game.hltb.source !== "hltb") return ""
    var matched = String(game.hltb.name || "")
    if (matched === "" || looseTitle(matched) === looseTitle(game.name)) return ""
    return "Matched \u201c" + matched + "\u201d"
  }

  // Nothing played, nothing in the bar — unless asked to stay.
  visible: games.length > 0 || steam.setting("alwaysShow", false) === true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    steam.rescanRunning()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: steam
    settings: root.settings
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    // `play` alone resumes the game you spent the most time on this week.
    function play(appId: string): string {
      var id = Number(appId)
      if (!(id > 0) && root.games.length > 0) id = Number(root.games[0].appId)
      if (!(id > 0)) return "no game"
      root.play(id)
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: steam.setting("showWeekInBar", false) === true && steam.weekMinutes > 0
      ? root.barGlyph + " " + steam.formatMinutes(steam.weekMinutes)
      : root.barGlyph
    active: root.playing
    tooltipText: ""
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchSteam()
      else if (buttonCode === Qt.MiddleButton && root.games.length > 0) root.play(root.games[0].appId)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        // Left folds the cursor's row, right unfolds it — the row is the
        // horizontal axis here, there is nothing else to switch between.
        if (dx !== 0 && root.cursorGame) {
          if (dx > 0) root.expandedAppId = Number(root.cursorGame.appId)
          else if (root.expandedAppId === Number(root.cursorGame.appId)) root.expandedAppId = 0
        }
      }
      onActivateRequested: if (root.cursorGame) root.toggleExpanded(root.cursorGame.appId)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if ((t === "p" || t === "P") && root.cursorGame) root.play(root.cursorGame.appId)
        else if (t === " " && root.cursorGame) root.toggleExpanded(root.cursorGame.appId)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: mark · Steam · week total ----------
          PanelHero {
            width: parent.width
            title: "Vapour"
            detail: root.heroDetail()
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.playing ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: steam.errorText !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: steam.errorText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            visible: root.games.length === 0 && steam.errorText === ""
            width: parent.width
            topPadding: Style.space(24)
            text: steam.record
              ? "Nothing played this week.\nGames show up here once you've launched them."
              : "Reading Steam playtime…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Hours by day ----------
          PanelSeparator {
            visible: daysSection.visible
            foreground: root.foreground
          }

          Column {
            id: daysSection
            visible: steam.hasDayHistory
            width: parent.width
            spacing: Style.spacing.md

            readonly property real peak: root.dayPeak()

            PanelSectionHeader {
              width: parent.width
              text: "HOURS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: steam.days

              DayRow {
                required property var modelData
                width: daysSection.width
                day: modelData
                ratio: Number(modelData.minutes || 0) / daysSection.peak
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Games ----------
          PanelSeparator {
            visible: gamesSection.visible
            foreground: root.foreground
          }

          Column {
            id: gamesSection
            visible: root.games.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "GAMES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: gamesList
              width: parent.width
              spacing: Style.spacing.sm

              Repeater {
                id: gamesRepeater
                model: root.games

                GameRow {
                  required property var modelData
                  required property int index
                  width: gamesList.width
                  game: modelData
                  // Scaled to the game you played most, so the top row is
                  // always full — the same scale-to-peak the day chart uses.
                  share: Number(modelData.weekMinutes || 0) / root.weekPeak()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // Rounded track showing how far along something is.
  component Meter: Item {
    id: meter
    property real value: -1
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, time. Today is picked out in full foreground;
  // a day with no snapshot on either side shows a dash rather than a fake zero.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    readonly property bool known: day && day.minutes !== null && day.minutes !== undefined

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: dayRow.today ? "Today" : root.dayName(dayRow.day ? dayRow.day.date : "")
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track
      opacity: dayRow.known ? 1 : 0.4

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: dayRow.known ? parent.width * root.clamp(dayRow.ratio, 0, 1) : 0
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: dayRow.known ? steam.formatMinutes(dayRow.day.minutes) : "—"
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(58)
    }
  }

  // A game: the share bar fills the row behind the name, a Play button sits
  // at the trailing edge, and a click on the row unfolds its rundown.
  component GameRow: Column {
    id: gameRow
    property var game: null
    property real share: 0

    readonly property int appId: game ? Number(game.appId) : 0
    readonly property bool expanded: appId !== 0 && root.expandedAppId === appId
    readonly property bool hasCursor: root.cursorActive && root.cursorAppId === appId
    readonly property bool running: steam.isRunning(appId)
    readonly property var progressInfo: root.progress(game)
    readonly property bool hltbVisible: !!game && (String(game.hltbStatus || "") !== "off" || !!game.hltb)

    spacing: 0

    CursorSurface {
      id: rowSurface
      width: parent.width
      implicitHeight: gameName.implicitHeight + Style.spacing.lg * 2
      hasCursor: gameRow.hasCursor
      current: gameRow.expanded
      foreground: root.foreground

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: root.alpha(root.foreground, 0.05)
        visible: !gameRow.hasCursor && !gameRow.expanded
      }

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * root.clamp(gameRow.share, 0, 1)
        radius: Style.cornerRadius
        color: root.alpha(root.foreground, 0.14)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }

      // The whole row, minus the Play button, toggles the rundown.
      MouseArea {
        id: rowHover
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: playButton.left
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) {
          root.cursorActive = true
          root.cursorAppId = gameRow.appId
        }
        onClicked: {
          root.cursorActive = true
          root.cursorAppId = gameRow.appId
          root.toggleExpanded(gameRow.appId)
        }
      }

      Text {
        id: playingDot
        textFormat: Text.PlainText
        visible: gameRow.running
        text: "●"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: gameName
        textFormat: Text.PlainText
        text: gameRow.game ? String(gameRow.game.name || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: gameRow.running
        elide: Text.ElideRight
        anchors.left: gameRow.running ? playingDot.right : parent.left
        anchors.leftMargin: Style.space(8)
        anchors.right: gameMinutes.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: gameMinutes
        textFormat: Text.PlainText
        text: gameRow.game ? steam.formatMinutes(gameRow.game.weekMinutes) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.right: playButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }

      PanelActionButton {
        id: playButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰐊"
        tooltipText: gameRow.running ? "Already running" : (gameRow.game && gameRow.game.installed === false ? "Play (installs first)" : "Play")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !gameRow.running
        onClicked: root.play(gameRow.appId)
      }

      PanelToolTip {
        visible: rowHover.containsMouse && !gameRow.expanded
        text: root.gameTooltip(gameRow.game)
        fontFamily: root.fontFamily
      }
    }

    // ---------- Rundown ----------
    Item {
      id: rundown
      width: parent.width
      clip: true
      implicitHeight: gameRow.expanded ? rundownColumn.implicitHeight + Style.space(10) : 0
      visible: implicitHeight > 0

      Behavior on implicitHeight {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      Column {
        id: rundownColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.space(6)
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(6)

        StatLine { label: "Total"; value: gameRow.game ? steam.formatMinutes(gameRow.game.totalMinutes) : "" }
        StatLine { label: "Last 2 weeks"; value: gameRow.game ? steam.formatMinutes(gameRow.game.twoWeekMinutes) : "" }
        StatLine { label: "Last played"; value: gameRow.game ? steam.formatLastPlayed(gameRow.game.lastPlayed, root.nowMs) : "" }
        StatLine {
          visible: gameRow.game && gameRow.game.installed === false
          label: "Installed"
          value: "Not on this machine"
        }

        Item { width: 1; height: Style.space(2); visible: gameRow.hltbVisible }

        Text {
          textFormat: Text.PlainText
          visible: gameRow.hltbVisible
          width: parent.width
          text: "HOW LONG TO BEAT"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: gameRow.hltbVisible
          text: gameRow.game && gameRow.game.hltb
            ? root.hltbLine(gameRow.game.hltb)
            : root.hltbStatusText(gameRow.game)
          color: gameRow.game && gameRow.game.hltb ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          width: parent.width
          text: root.hltbMatchNote(gameRow.game)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Meter {
          visible: !!gameRow.progressInfo
          width: parent.width
          value: gameRow.progressInfo ? gameRow.progressInfo.ratio : -1
        }

        Text {
          textFormat: Text.PlainText
          visible: !!gameRow.progressInfo
          width: parent.width
          text: gameRow.progressInfo ? gameRow.progressInfo.text : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // Label on the left, value on the right — one line of the rundown.
  component StatLine: Item {
    id: statLine
    property string label: ""
    property string value: ""

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)

    Text {
      id: statLabel
      textFormat: Text.PlainText
      text: statLine.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: statValue
      textFormat: Text.PlainText
      text: statLine.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
