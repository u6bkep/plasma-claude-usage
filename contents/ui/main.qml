import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // Translations
    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    property real sessionUsagePercent: 0
    property real weeklyUsagePercent: 0
    property real sonnetWeeklyPercent: 0
    property real opusWeeklyPercent: 0
    property string lastUpdate: ""
    property string planName: ""
    property string sessionReset: ""
    property string weeklyReset: ""
    property string errorMsg: ""
    property string accessToken: ""
    property bool isLoading: false
    property var sessionResetTime: null
    property var weeklyResetTime: null

    // Low power mode and slow polling state
    property bool inLowPowerMode: false
    property bool inSlowPollingMode: false
    property int unchangedPollCount: 0
    property real lastSessionUsage: -1
    property real lastWeeklyUsage: -1

    readonly property string usageApiUrl: "https://api.anthropic.com/api/oauth/usage"

    // Data source for reading credentials file
    Plasma5Support.DataSource {
        id: fileReader
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            disconnectSource(sourceName)

            console.log("Claude Usage: Got credentials, length:", stdout.length)

            if (stdout.length > 10) {
                try {
                    var creds = JSON.parse(stdout)
                    var oauth = creds.claudeAiOauth || {}
                    root.accessToken = oauth.accessToken || ""

                    // Get plan name from tier
                    var tier = oauth.rateLimitTier || "default_claude_pro"
                    var planMap = {
                        "default_claude_pro": "Pro",
                        "default_claude_max_5x": "Max 5x",
                        "default_claude_max_20x": "Max 20x"
                    }
                    root.planName = planMap[tier] || tier

                    console.log("Claude Usage: Token found, plan:", root.planName)

                    if (root.accessToken) {
                        fetchUsageFromApi()
                    } else {
                        root.errorMsg = i18n.tr("Not logged in")
                        root.isLoading = false
                    }
                } catch (e) {
                    console.log("Claude Usage: Failed to parse credentials:", e)
                    root.errorMsg = "Not logged in"
                    root.isLoading = false
                }
            } else {
                console.log("Claude Usage: No credentials file found")
                root.errorMsg = "Not logged in"
                root.isLoading = false
            }
        }
    }

    function loadCredentials() {
        root.isLoading = true
        root.errorMsg = ""
        // Use $HOME environment variable
        fileReader.connectSource("cat $HOME/.claude/.credentials.json 2>/dev/null")
    }

    function fetchUsageFromApi() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", usageApiUrl)
        xhr.setRequestHeader("Authorization", "Bearer " + root.accessToken)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                root.isLoading = false

                if (xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText)

                        var fiveHour = data.five_hour || {}
                        var sevenDay = data.seven_day || {}
                        var sevenDaySonnet = data.seven_day_sonnet || {}
                        var sevenDayOpus = data.seven_day_opus || {}

                        var newSessionUsage = fiveHour.utilization || 0
                        var newWeeklyUsage = sevenDay.utilization || 0

                        // Check if values have changed for slow polling logic
                        if (Plasmoid.configuration.slowPollingEnabled) {
                            if (root.lastSessionUsage === newSessionUsage && root.lastWeeklyUsage === newWeeklyUsage) {
                                root.unchangedPollCount++
                                if (root.unchangedPollCount >= Plasmoid.configuration.slowPollingThreshold && !root.inSlowPollingMode) {
                                    root.inSlowPollingMode = true
                                    console.log("Claude Usage: Entering slow polling mode after", root.unchangedPollCount, "unchanged polls")
                                }
                            } else {
                                root.unchangedPollCount = 0
                                if (root.inSlowPollingMode) {
                                    root.inSlowPollingMode = false
                                    console.log("Claude Usage: Exiting slow polling mode - values changed")
                                }
                            }
                        }

                        root.lastSessionUsage = newSessionUsage
                        root.lastWeeklyUsage = newWeeklyUsage
                        root.sessionUsagePercent = newSessionUsage
                        root.weeklyUsagePercent = newWeeklyUsage
                        root.sonnetWeeklyPercent = sevenDaySonnet ? (sevenDaySonnet.utilization || 0) : 0
                        root.opusWeeklyPercent = sevenDayOpus ? (sevenDayOpus.utilization || 0) : 0

                        if (fiveHour.resets_at) {
                            root.sessionResetTime = new Date(fiveHour.resets_at)
                            root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
                        }
                        if (sevenDay.resets_at) {
                            root.weeklyResetTime = new Date(sevenDay.resets_at)
                            root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
                        }

                        // Check for low power mode (session at 100%)
                        if (Plasmoid.configuration.lowPowerModeEnabled && newSessionUsage >= 100) {
                            if (!root.inLowPowerMode) {
                                root.inLowPowerMode = true
                                console.log("Claude Usage: Entering low power mode - session at 100%")
                            }
                        } else if (root.inLowPowerMode) {
                            root.inLowPowerMode = false
                            console.log("Claude Usage: Exiting low power mode")
                        }

                        root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                        root.errorMsg = ""

                        console.log("Claude Usage: API success - session:", root.sessionUsagePercent, "weekly:", root.weeklyUsagePercent, "lowPower:", root.inLowPowerMode, "slowPoll:", root.inSlowPollingMode)
                    } catch (e) {
                        console.log("Claude Usage: JSON parse error:", e)
                        root.errorMsg = "Parse error"
                    }
                } else if (xhr.status === 401) {
                    root.errorMsg = i18n.tr("Token expired")
                    console.log("Claude Usage: 401 Unauthorized")
                } else {
                    root.errorMsg = i18n.tr("API error") + " (" + xhr.status + ")"
                    console.log("Claude Usage: API error:", xhr.status, xhr.statusText)
                }
            }
        }

        xhr.send()
    }

    function refresh() {
        // Manual refresh exits low power and slow polling modes
        root.inLowPowerMode = false
        root.inSlowPollingMode = false
        root.unchangedPollCount = 0
        loadCredentials()
    }

    // Compact representation (panel) - shows both percentages
    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            // Claude icon
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: Qt.resolvedUrl("../icons/claude.svg")
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Error state
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: "⚠"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }

            // Normal state
            Rectangle {
                visible: root.errorMsg === ""
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.sessionUsagePercent)
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === ""
                text: Math.round(root.sessionUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === ""
                text: "|"
                opacity: 0.5
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
            }

            Rectangle {
                visible: root.errorMsg === ""
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.weeklyUsagePercent)
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === ""
                text: Math.round(root.weeklyUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
            }

            // Error text
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: root.errorMsg
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }
        }
    }

    // Full representation (popup)
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        Layout.preferredWidth: Kirigami.Units.gridUnit * 16
        Layout.preferredHeight: Kirigami.Units.gridUnit * 18

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.mediumSpacing

            // Header
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: i18n.tr("Claude Usage")
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                    Layout.preferredHeight: planLabel.implicitHeight + Kirigami.Units.smallSpacing
                    radius: 3
                    color: Kirigami.Theme.highlightColor
                    PlasmaComponents.Label {
                        id: planLabel
                        anchors.centerIn: parent
                        text: root.planName
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.highlightedTextColor
                    }
                }
            }

            // Error message
            Rectangle {
                visible: root.errorMsg !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: errorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.negativeBackgroundColor

                ColumnLayout {
                    id: errorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + root.errorMsg
                        color: Kirigami.Theme.negativeTextColor
                        font.bold: true
                    }
                    PlasmaComponents.Label {
                        text: i18n.tr("Run 'claude' to log in")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.negativeTextColor
                    }
                }
            }

            // Separator
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Session Usage
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: i18n.tr("Session (5hr)")
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: root.sessionUsagePercent.toFixed(1) + "%"
                        color: getUsageColor(root.sessionUsagePercent)
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.sessionUsagePercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getUsageColor(root.sessionUsagePercent)
                    }
                }

                PlasmaComponents.Label {
                    visible: root.sessionReset !== ""
                    text: i18n.tr("Resets at:") + " " + root.sessionReset + (root.sessionResetTime ? " (" + formatTimeRemaining(root.sessionResetTime) + ")" : "")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Weekly Usage
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: i18n.tr("Weekly (7day)")
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: root.weeklyUsagePercent.toFixed(1) + "%"
                        color: getUsageColor(root.weeklyUsagePercent)
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.weeklyUsagePercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getUsageColor(root.weeklyUsagePercent)
                    }
                }

                PlasmaComponents.Label {
                    visible: root.weeklyReset !== ""
                    text: i18n.tr("Resets:") + " " + root.weeklyReset + (root.weeklyResetTime ? " (" + formatTimeRemaining(root.weeklyResetTime) + ")" : "")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Separator
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Model breakdown
            PlasmaComponents.Label {
                text: i18n.tr("By Model (Weekly)")
                font.bold: true
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }

            // Sonnet
            RowLayout {
                Layout.fillWidth: true
                visible: root.sonnetWeeklyPercent > 0

                PlasmaComponents.Label {
                    text: i18n.tr("Sonnet")
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: 60
                    height: 8
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.sonnetWeeklyPercent / 100, 1)
                        height: parent.height
                        radius: 3
                        color: getUsageColor(root.sonnetWeeklyPercent)
                    }
                }
                PlasmaComponents.Label {
                    text: root.sonnetWeeklyPercent.toFixed(0) + "%"
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                }
            }

            // Opus
            RowLayout {
                Layout.fillWidth: true
                visible: root.opusWeeklyPercent > 0

                PlasmaComponents.Label {
                    text: i18n.tr("Opus")
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: 60
                    height: 8
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.opusWeeklyPercent / 100, 1)
                        height: parent.height
                        radius: 3
                        color: getUsageColor(root.opusWeeklyPercent)
                    }
                }
                PlasmaComponents.Label {
                    text: root.opusWeeklyPercent.toFixed(0) + "%"
                    Layout.preferredWidth: 40
                    horizontalAlignment: Text.AlignRight
                }
            }

            // No model data message
            PlasmaComponents.Label {
                visible: root.sonnetWeeklyPercent === 0 && root.opusWeeklyPercent === 0
                text: i18n.tr("No model breakdown available")
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
                font.italic: true
            }

            Item { Layout.fillHeight: true }

            // Footer
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Polling mode indicator
            RowLayout {
                Layout.fillWidth: true
                visible: root.inLowPowerMode || root.inSlowPollingMode

                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    source: root.inLowPowerMode ? "battery-low" : "speedometer"
                }
                PlasmaComponents.Label {
                    text: root.inLowPowerMode ? i18n.tr("Low power mode - paused until session resets") : i18n.tr("Slow polling mode")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                    font.italic: true
                }
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.lastUpdate !== "" ? i18n.tr("Updated:") + " " + root.lastUpdate : i18n.tr("Loading...")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Button {
                    icon.name: "view-refresh"
                    text: i18n.tr("Refresh")
                    onClicked: refresh()
                }
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: {
            if (root.inSlowPollingMode) {
                return (Plasmoid.configuration.slowPollingInterval || 5) * 60000
            }
            return (Plasmoid.configuration.refreshInterval || 1) * 60000
        }
        running: !root.inLowPowerMode
        repeat: true
        onTriggered: loadCredentials()
    }

    // Timer to check if session reset time has passed (for low power mode)
    Timer {
        id: lowPowerResetTimer
        interval: 60000  // Check every minute
        running: root.inLowPowerMode && root.sessionResetTime !== null
        repeat: true
        onTriggered: {
            if (root.sessionResetTime && new Date() >= root.sessionResetTime) {
                console.log("Claude Usage: Session reset time reached, resuming polling")
                root.inLowPowerMode = false
                loadCredentials()
            }
        }
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function formatTimeRemaining(resetTime) {
        if (!resetTime) return ""
        var now = new Date()
        var diff = resetTime.getTime() - now.getTime()
        if (diff <= 0) return ""

        var hours = Math.floor(diff / (1000 * 60 * 60))
        var minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60))

        if (hours > 24) {
            var days = Math.floor(hours / 24)
            hours = hours % 24
            return days + i18n.tr("d") + " " + hours + i18n.tr("h")
        } else if (hours > 0) {
            return hours + i18n.tr("h") + " " + minutes + i18n.tr("m")
        } else {
            return minutes + i18n.tr("m")
        }
    }

    Component.onCompleted: {
        console.log("Claude Usage: Widget loaded")
        loadCredentials()
    }

    Plasmoid.icon: "claude-usage"
    toolTipMainText: i18n.tr("Claude Usage")
    toolTipSubText: {
        var text = i18n.tr("Session (5hr)") + ": " + Math.round(root.sessionUsagePercent) + "% | " + i18n.tr("Weekly (7day)") + ": " + Math.round(root.weeklyUsagePercent) + "%"
        if (root.inLowPowerMode) {
            text += "\n" + i18n.tr("Low power mode (paused until reset)")
        } else if (root.inSlowPollingMode) {
            text += "\n" + i18n.tr("Slow polling mode")
        }
        return text
    }
}
