import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.core as PlasmaCore

PlasmoidItem {
    id: root

    // Translations
    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    property real sessionUsagePercent: 0
    property real weeklyUsagePercent: 0
    // Per-model weekly usage, derived from the API's limits[] scoped entries.
    // Each element: { name: string, percent: real, active: bool }. Dynamic, so
    // new models (Fable, etc.) appear automatically with no code changes.
    property var modelUsages: []
    readonly property bool hasModelData: root.modelUsages.length > 0
    // The single model most worth surfacing in the compact panel: highest utilization.
    readonly property var topModel: {
        if (root.modelUsages.length === 0) return null
        var best = root.modelUsages[0]
        for (var i = 1; i < root.modelUsages.length; i++) {
            if (root.modelUsages[i].percent > best.percent) best = root.modelUsages[i]
        }
        return best
    }
    readonly property string topModelName: root.topModel ? root.topModel.name : ""
    readonly property real topModelPercent: root.topModel ? root.topModel.percent : 0
    property double lastUpdateTime: 0
    property bool lastUpdateFromCache: false
    readonly property string lastUpdate: lastUpdateTime > 0
        ? formatClockTime(new Date(lastUpdateTime), true) + (lastUpdateFromCache ? " *" : "")
        : ""
    property string planName: ""
    readonly property bool use12HourFormat: Plasmoid.configuration.use12HourFormat === true
    readonly property string sessionReset: sessionResetTime ? formatClockTime(sessionResetTime, false) : ""
    readonly property string weeklyReset: weeklyResetTime ? formatResetDateTime(weeklyResetTime) : ""
    property string errorMsg: ""
    property string accessToken: ""
    property string apiKey: ""
    property string baseUrl: ""
    property bool isLoading: false
    property var sessionResetTime: null
    property var weeklyResetTime: null
    property bool hasTokenError: false
    property bool hasRateLimitError: false
    // Transient server-side failure (5xx or network): keep showing cached data
    property bool hasServerError: false
    property int errorStatus: 0
    property string errorDetail: ""  // actual error message returned by the endpoint
    property int rateLimitRetryCount: 0
    property int rateLimitRetryMs: 0  // from retry-after header
    property double lastFetchTime: 0
    property double lastSuccessTime: 0
    property bool isStale: false
    readonly property int minFetchIntervalMs: 55000  // just under 1 minute
    // Stale threshold: if rate limited, use retry-after + buffer; otherwise 3x refresh interval
    readonly property int staleThresholdMs: root.hasRateLimitError && root.rateLimitRetryMs > 0
        ? root.rateLimitRetryMs + 60000
        : Math.max(Plasmoid.configuration.refreshInterval || 1, 1) * 60000 * 3

    // Low power mode and slow polling state
    property bool inLowPowerMode: false
    property bool inSlowPollingMode: false
    property int unchangedPollCount: 0
    property real lastSessionUsage: -1
    property real lastWeeklyUsage: -1

    // Configured Claude base folder (contains .credentials.json); shell expands $HOME/~
    readonly property string claudeBaseFolder: Plasmoid.configuration.claudeBaseFolder || "$HOME/.claude"

    // Cache writer - saves last successful data to file
    Plasma5Support.DataSource {
        id: cacheWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) { disconnectSource(sourceName) }
    }

    // Cache reader - loads cached data on startup
    Plasma5Support.DataSource {
        id: cacheReader
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = (data["stdout"] || "").trim()
            disconnectSource(sourceName)
            if (stdout.length > 10) {
                try {
                    var cache = JSON.parse(stdout)
                    var age = Date.now() - (cache.timestamp || 0)
                    if (age < 86400000) { // less than 24 hours old
                        root.sessionUsagePercent = cache.session || 0
                        root.weeklyUsagePercent = cache.weekly || 0
                        root.modelUsages = cache.models || []
                        root.planName = cache.plan || ""
                        root.sessionResetTime = cache.sessionResetTs ? new Date(cache.sessionResetTs) : null
                        root.weeklyResetTime = cache.weeklyResetTs ? new Date(cache.weeklyResetTs) : null
                        root.lastSuccessTime = cache.timestamp
                        root.lastUpdateTime = cache.timestamp
                        root.lastUpdateFromCache = true
                        root.isStale = age > root.staleThresholdMs
                        console.log("Claude Usage: Loaded cache, age:", Math.round(age/60000), "min, stale:", root.isStale)
                    } else {
                        console.log("Claude Usage: Cache too old, ignoring")
                    }
                } catch (e) {
                    console.log("Claude Usage: Cache parse error:", e)
                }
            }
        }
    }

    function saveCache() {
        var cache = {
            session: root.sessionUsagePercent,
            weekly: root.weeklyUsagePercent,
            models: root.modelUsages,
            plan: root.planName,
            sessionResetTs: root.sessionResetTime ? root.sessionResetTime.getTime() : null,
            weeklyResetTs: root.weeklyResetTime ? root.weeklyResetTime.getTime() : null,
            timestamp: Date.now()
        }
        var json = JSON.stringify(cache)
        cacheWriter.connectSource("echo '" + json.replace(/'/g, "'\\''") + "' > $HOME/.local/share/claude-usage-cache.json")
    }

    // Stale checker - updates isStale flag periodically
    Timer {
        id: staleTimer
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            if (root.lastSuccessTime > 0) {
                root.isStale = (Date.now() - root.lastSuccessTime) > root.staleThresholdMs
            }
        }
    }

    // Token watcher - polls credentials file during rate limit to detect token refresh
    Plasma5Support.DataSource {
        id: tokenWatcher
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = (data["stdout"] || "").trim()
            disconnectSource(sourceName)
            if (stdout.length > 10) {
                try {
                    var creds = JSON.parse(stdout)
                    var newToken = (creds.claudeAiOauth || {}).accessToken || ""
                    if (newToken && newToken !== root.accessToken) {
                        console.log("Claude Usage: New token detected! Resetting rate limit state.")
                        root.accessToken = newToken
                        root.hasRateLimitError = false
                        root.rateLimitRetryCount = 0
                        root.lastFetchTime = 0
                        fetchUsageFromApi(true)
                    }
                } catch (e) {
                    console.log("Claude Usage: Token watcher parse error:", e)
                }
            }
        }
    }

    Timer {
        id: tokenWatchTimer
        interval: 30000  // check every 30 seconds
        running: root.hasRateLimitError && !root.baseUrl
        repeat: true
        onTriggered: {
            tokenWatcher.connectSource("cat " + root.claudeBaseFolder + "/.credentials.json 2>/dev/null")
        }
    }

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
                        root.errorDetail = ""
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
                root.errorDetail = ""
                root.isLoading = false
            }
        }
    }

    // Honest User-Agent identifying this widget. We deliberately do NOT spoof the
    // real "claude-code/<version>" agent: impersonating the official client risks
    // the account being flagged. An identifiable agent is the safer middle ground.
    property string userAgent: "plasma-claude-usage-widget"

    // Data source for launching claude in terminal
    Plasma5Support.DataSource {
        id: claudeLauncher
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            disconnectSource(sourceName)
            console.log("Claude Usage: Terminal launched")
        }
    }

    function loadCredentials() {
        root.isLoading = true
        root.errorMsg = ""
        var configBaseUrl = (Plasmoid.configuration.baseUrl || "").trim()
        if (configBaseUrl) {
            root.baseUrl = configBaseUrl.replace(/\/$/, "")
            root.apiKey = (Plasmoid.configuration.apiKey || "").trim()
            root.planName = "API Key"
            console.log("Claude Usage: Using configured base URL:", root.baseUrl)
            if (root.apiKey) {
                fetchUsageFromApi()
            } else {
                root.errorMsg = "API key not configured"
                root.errorDetail = ""
                root.isLoading = false
            }
        } else {
            root.baseUrl = ""
            root.apiKey = ""
            console.log("Claude Usage: No base URL configured, reading credentials file from", root.claudeBaseFolder)
            fileReader.connectSource("cat " + root.claudeBaseFolder + "/.credentials.json 2>/dev/null")
        }
    }

    // Pull a human-readable message out of an error response. Anthropic API errors
    // are JSON ({"error":{"message":...}}), but proxy-level failures arrive as plain
    // text (e.g. 503 "upstream connect error ... reset reason: overflow").
    function extractErrorDetail(xhr) {
        var text = (xhr.responseText || "").trim()
        if (!text) return ""
        try {
            var parsed = JSON.parse(text)
            if (parsed.error && parsed.error.message) return parsed.error.message
            if (parsed.message) return parsed.message
        } catch (e) {}
        text = text.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim()
        return text.length > 200 ? text.substring(0, 200) + "…" : text
    }

    function fetchUsageFromApi(force) {
        var now = Date.now()
        if (!force && root.lastFetchTime > 0 && (now - root.lastFetchTime) < root.minFetchIntervalMs) {
            console.log("Claude Usage: Skipping fetch, too soon since last request")
            root.isLoading = false
            return
        }
        root.lastFetchTime = now

        var url = root.baseUrl
            ? root.baseUrl + "/api/oauth/usage"
            : "https://api.anthropic.com/api/oauth/usage"

        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("User-Agent", root.userAgent)
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")

        if (root.baseUrl) {
            // Custom base URL: authenticate with API key
            xhr.setRequestHeader("x-api-key", root.apiKey)
        } else {
            // Default: OAuth token from credentials file
            xhr.setRequestHeader("Authorization", "Bearer " + root.accessToken)
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                root.isLoading = false

                if (xhr.status !== 200) {
                    root.errorStatus = xhr.status
                    root.errorDetail = extractErrorDetail(xhr)
                }

                if (xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText)

                        var fiveHour = data.five_hour || {}
                        var sevenDay = data.seven_day || {}

                        var newSessionUsage = fiveHour.utilization || 0
                        var newWeeklyUsage = sevenDay.utilization || 0
                        var sessionResetSrc = fiveHour.resets_at
                        var weeklyResetSrc = sevenDay.resets_at
                        var models = []

                        // The limits[] array (new API) is the structured, self-describing source:
                        // it enumerates the session limit, the weekly total, and one scoped entry
                        // per model, so we don't hardcode model names. Fall back to the legacy
                        // top-level keys for older Claude installs that don't return limits[].
                        if (data.limits && data.limits.length > 0) {
                            for (var li = 0; li < data.limits.length; li++) {
                                var lim = data.limits[li]
                                if (lim.kind === "session") {
                                    newSessionUsage = lim.percent || 0
                                    if (lim.resets_at) sessionResetSrc = lim.resets_at
                                } else if (lim.kind === "weekly_all") {
                                    newWeeklyUsage = lim.percent || 0
                                    if (lim.resets_at) weeklyResetSrc = lim.resets_at
                                } else if (lim.kind === "weekly_scoped" && lim.scope && lim.scope.model && lim.scope.model.display_name) {
                                    models.push({
                                        name: lim.scope.model.display_name,
                                        percent: lim.percent || 0,
                                        active: lim.is_active === true
                                    })
                                }
                            }
                        } else {
                            if (data.seven_day_sonnet)
                                models.push({ name: i18n.tr("Sonnet"), percent: data.seven_day_sonnet.utilization || 0, active: false })
                            if (data.seven_day_opus)
                                models.push({ name: i18n.tr("Opus"), percent: data.seven_day_opus.utilization || 0, active: false })
                        }

                        // Slow polling: count consecutive unchanged polls
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
                        root.modelUsages = models

                        if (sessionResetSrc) {
                            root.sessionResetTime = new Date(sessionResetSrc)
                        }
                        if (weeklyResetSrc) {
                            root.weeklyResetTime = new Date(weeklyResetSrc)
                        }

                        root.lastUpdateTime = Date.now()
                        root.lastUpdateFromCache = false
                        root.lastSuccessTime = Date.now()
                        root.isStale = false
                        root.errorMsg = ""
                        root.errorDetail = ""
                        root.errorStatus = 0
                        root.hasTokenError = false
                        root.hasRateLimitError = false
                        root.hasServerError = false
                        root.rateLimitRetryCount = 0
                        root.rateLimitRetryMs = 0

                        // Low power mode: pause polling once session hits 100%
                        if (Plasmoid.configuration.lowPowerModeEnabled && newSessionUsage >= 100) {
                            if (!root.inLowPowerMode) {
                                root.inLowPowerMode = true
                                console.log("Claude Usage: Entering low power mode - session at 100%")
                            }
                        } else if (root.inLowPowerMode) {
                            root.inLowPowerMode = false
                            console.log("Claude Usage: Exiting low power mode")
                        }

                        saveCache()

                        console.log("Claude Usage: API success - session:", root.sessionUsagePercent, "weekly:", root.weeklyUsagePercent, "lowPower:", root.inLowPowerMode, "slowPoll:", root.inSlowPollingMode)
                    } catch (e) {
                        console.log("Claude Usage: JSON parse error:", e)
                        root.errorMsg = "Parse error"
                    }
                } else if (xhr.status === 401) {
                    // Clear any stale rate-limit state so a prior 429 can't keep the retry timer firing
                    root.hasRateLimitError = false
                    root.hasServerError = false
                    root.rateLimitRetryCount = 0
                    if (root.baseUrl) {
                        root.errorMsg = i18n.tr("Invalid API key")
                        console.log("Claude Usage: 401 Unauthorized - invalid API key")
                    } else {
                        console.log("Claude Usage: 401 Unauthorized - token expired")
                        root.hasTokenError = true
                        root.errorMsg = ""
                    }
                } else if (xhr.status === 403) {
                    // Token lacks the required scope (e.g. user:profile). Show the re-login UI
                    // and stop the retry loop instead of falling through to a generic error.
                    console.log("Claude Usage: 403 Forbidden - token missing required scope")
                    root.hasTokenError = true
                    root.hasRateLimitError = false
                    root.hasServerError = false
                    root.rateLimitRetryCount = 0
                    root.errorMsg = ""
                } else if (xhr.status === 404) {
                    root.hasServerError = false
                    root.errorMsg = root.baseUrl
                        ? i18n.tr("Endpoint not found")
                        : i18n.tr("API error") + " (404)"
                    console.log("Claude Usage: 404 Not Found:", url)
                } else if (xhr.status === 429) {
                    var retryAfter = parseInt(xhr.getResponseHeader("retry-after") || "0")
                    if (retryAfter > 0) {
                        root.rateLimitRetryMs = retryAfter * 1000
                    }
                    root.rateLimitRetryCount++
                    console.log("Claude Usage: 429 Rate limited (retry #" + root.rateLimitRetryCount + ", retry-after: " + retryAfter + "s, waiting: " + root.rateLimitBackoffMs/1000 + "s)")
                    root.hasRateLimitError = true
                    root.hasServerError = false
                    root.lastFetchTime = 0  // allow retry timer to work
                    root.errorMsg = ""
                } else if (xhr.status >= 500 || xhr.status === 0) {
                    // Transient server or network failure: keep showing the cached
                    // values (dimmed) in the panel; the popup surfaces the endpoint's
                    // own error message so outages are distinguishable from auth issues
                    console.log("Claude Usage: Server error:", xhr.status, "-", root.errorDetail)
                    root.hasServerError = true
                    root.hasTokenError = false
                    root.hasRateLimitError = false
                    root.errorMsg = ""
                } else {
                    root.hasServerError = false
                    root.errorMsg = i18n.tr("API error") + " (" + xhr.status + ")"
                    console.log("Claude Usage: API error:", xhr.status, "-", root.errorDetail)
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
        root.hasTokenError = false
        root.hasRateLimitError = false
        root.hasServerError = false
        root.errorDetail = ""
        root.errorStatus = 0
        root.rateLimitRetryCount = 0
        root.rateLimitRetryMs = 0
        loadCredentials()
    }

    // Compact representation (panel)
    readonly property bool isVerticalLayout: Plasmoid.configuration.panelLayout === "vertical"

    // Panel items dim whenever the shown data may be out of date (any error state or stale cache)
    readonly property real dataOpacity: (hasTokenError || hasRateLimitError || hasServerError) ? 0.5 : isStale ? 0.6 : 1.0
    readonly property real separatorOpacity: dataOpacity * 0.5

    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: root.isVerticalLayout ? usageRow.implicitHeight + Kirigami.Units.largeSpacing * 2 : Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: root.isVerticalLayout ? usageRow.implicitHeight + Kirigami.Units.largeSpacing * 2 : -1

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        GridLayout {
            id: usageRow
            anchors.centerIn: parent
            columns: root.isVerticalLayout ? 1 : -1
            rows: root.isVerticalLayout ? -1 : 1
            flow: root.isVerticalLayout ? GridLayout.TopToBottom : GridLayout.LeftToRight
            columnSpacing: Kirigami.Units.smallSpacing
            rowSpacing: Kirigami.Units.smallSpacing / 2

            // Claude icon with error indicator
            Item {
                visible: Plasmoid.configuration.showIcon !== false
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.rightMargin: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    anchors.fill: parent
                    source: Qt.resolvedUrl("../icons/claude.svg")
                }

                // Error indicator dot: red for token/rate limit, orange for transient server errors
                Rectangle {
                    visible: root.hasTokenError || root.hasRateLimitError || root.hasServerError
                    width: 8
                    height: 8
                    radius: 4
                    color: root.hasServerError ? Kirigami.Theme.neutralTextColor : Kirigami.Theme.negativeTextColor
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: -2
                    anchors.bottomMargin: -2
                }
            }

            // Error state (non-token errors)
            PlasmaComponents.Label {
                visible: root.errorMsg !== "" && !root.hasTokenError && !root.hasRateLimitError
                text: "⚠"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }

            // === TEXT STYLE ===

            // Session usage (text)
            Rectangle {
                visible: (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showSession !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.sessionUsagePercent)
                opacity: root.dataOpacity
            }

            PlasmaComponents.Label {
                visible: (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showSession !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                text: Math.round(root.sessionUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
                opacity: root.dataOpacity
            }

            // Separator session-weekly (text)
            PlasmaComponents.Label {
                visible: !root.isVerticalLayout && (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showSession !== false) && (Plasmoid.configuration.showWeekly !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                text: "|"
                opacity: root.separatorOpacity
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
            }

            // Weekly usage (text)
            Rectangle {
                visible: (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showWeekly !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.weeklyUsagePercent)
                opacity: root.dataOpacity
            }

            PlasmaComponents.Label {
                visible: (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showWeekly !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                text: Math.round(root.weeklyUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
                opacity: root.dataOpacity
            }

            // Separator before top model (text)
            PlasmaComponents.Label {
                visible: !root.isVerticalLayout && (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showTopModel === true) && root.hasModelData && ((Plasmoid.configuration.showSession !== false) || (Plasmoid.configuration.showWeekly !== false)) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                text: "|"
                opacity: root.separatorOpacity
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
            }

            // Top model usage (text)
            Rectangle {
                visible: (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showTopModel === true) && root.hasModelData && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.topModelPercent)
                opacity: root.dataOpacity
            }

            PlasmaComponents.Label {
                visible: (!Plasmoid.configuration.panelStyle || Plasmoid.configuration.panelStyle === "text") && (Plasmoid.configuration.showTopModel === true) && root.hasModelData && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                text: Math.round(root.topModelPercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
                opacity: root.dataOpacity
            }

            // === CIRCULAR STYLE ===

            // Session (circular)
            Item {
                visible: Plasmoid.configuration.panelStyle === "circular" && (Plasmoid.configuration.showSession !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                opacity: root.dataOpacity

                Canvas {
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        drawCircularProgress(ctx, width, height, root.sessionUsagePercent)
                    }
                    property real _percent: root.sessionUsagePercent
                    on_PercentChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: Math.round(root.sessionUsagePercent)
                    font.pixelSize: 9
                    font.bold: true
                }
            }

            // Weekly (circular)
            Item {
                visible: Plasmoid.configuration.panelStyle === "circular" && (Plasmoid.configuration.showWeekly !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                opacity: root.dataOpacity

                Canvas {
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        drawCircularProgress(ctx, width, height, root.weeklyUsagePercent)
                    }
                    property real _percent: root.weeklyUsagePercent
                    on_PercentChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: Math.round(root.weeklyUsagePercent)
                    font.pixelSize: 9
                    font.bold: true
                }
            }

            // Top model (circular)
            Item {
                visible: Plasmoid.configuration.panelStyle === "circular" && (Plasmoid.configuration.showTopModel === true) && root.hasModelData && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                opacity: root.dataOpacity

                Canvas {
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        drawCircularProgress(ctx, width, height, root.topModelPercent)
                    }
                    property real _percent: root.topModelPercent
                    on_PercentChanged: requestPaint()
                    Component.onCompleted: requestPaint()
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: Math.round(root.topModelPercent)
                    font.pixelSize: 9
                    font.bold: true
                }
            }

            // === BAR STYLE ===

            // Session (bar)
            Item {
                visible: Plasmoid.configuration.panelStyle === "bar" && (Plasmoid.configuration.showSession !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 32
                Layout.preferredHeight: parent.height
                opacity: root.dataOpacity

                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 1
                        height: Math.max((parent.height - 2) * Math.min(root.sessionUsagePercent / 100, 1), 1)
                        radius: 2
                        color: getUsageColor(root.sessionUsagePercent)
                    }
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: Math.round(root.sessionUsagePercent)
                    font.pixelSize: 9
                    font.bold: true
                }
            }

            // Weekly (bar)
            Item {
                visible: Plasmoid.configuration.panelStyle === "bar" && (Plasmoid.configuration.showWeekly !== false) && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 32
                Layout.preferredHeight: parent.height
                opacity: root.dataOpacity

                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 1
                        height: Math.max((parent.height - 2) * Math.min(root.weeklyUsagePercent / 100, 1), 1)
                        radius: 2
                        color: getUsageColor(root.weeklyUsagePercent)
                    }
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: Math.round(root.weeklyUsagePercent)
                    font.pixelSize: 9
                    font.bold: true
                }
            }

            // Top model (bar)
            Item {
                visible: Plasmoid.configuration.panelStyle === "bar" && (Plasmoid.configuration.showTopModel === true) && root.hasModelData && (root.errorMsg === "" || root.hasTokenError || root.hasRateLimitError)
                Layout.preferredWidth: 32
                Layout.preferredHeight: parent.height
                opacity: root.dataOpacity

                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1

                    Rectangle {
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 1
                        height: Math.max((parent.height - 2) * Math.min(root.topModelPercent / 100, 1), 1)
                        radius: 2
                        color: getUsageColor(root.topModelPercent)
                    }
                }

                PlasmaComponents.Label {
                    anchors.centerIn: parent
                    text: Math.round(root.topModelPercent)
                    font.pixelSize: 9
                    font.bold: true
                }
            }

            // Error text (non-token errors only)
            PlasmaComponents.Label {
                visible: root.errorMsg !== "" && !root.hasTokenError && !root.hasRateLimitError
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

            // Error message (regular errors)
            Rectangle {
                visible: root.errorMsg !== "" && !root.hasTokenError && !root.hasRateLimitError
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
                    // Prefer the endpoint's own error message over a generic hint:
                    // "upstream connect error... overflow" tells the user far more
                    // than a canned suggestion to re-login would
                    PlasmaComponents.Label {
                        text: root.errorDetail !== ""
                            ? root.errorDetail
                            : (root.baseUrl
                                ? i18n.tr("Check base URL and API key in widget settings")
                                : i18n.tr("Run 'claude' to log in"))
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.negativeTextColor
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
            }

            // Token error message
            Rectangle {
                visible: root.hasTokenError
                Layout.fillWidth: true
                Layout.preferredHeight: tokenErrorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.negativeBackgroundColor

                ColumnLayout {
                    id: tokenErrorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + i18n.tr("Re-login required")
                        color: Kirigami.Theme.negativeTextColor
                        font.bold: true
                    }

                    PlasmaComponents.Button {
                        text: i18n.tr("Open Claude")
                        icon.name: "utilities-terminal"
                        onClicked: {
                            claudeLauncher.connectSource("bash -c 'cd $HOME && if command -v konsole >/dev/null; then konsole --hold -e env -u CLAUDECODE bash -lc claude; elif command -v gnome-terminal >/dev/null; then gnome-terminal -- env -u CLAUDECODE bash -lc \"claude; exec bash\"; elif command -v xfce4-terminal >/dev/null; then xfce4-terminal --hold -e \"env -u CLAUDECODE bash -lc claude\"; elif command -v xterm >/dev/null; then xterm -hold -e env -u CLAUDECODE bash -lc claude; fi &'")
                        }
                    }
                }
            }

            // Rate limit error message
            Rectangle {
                visible: root.hasRateLimitError
                Layout.fillWidth: true
                Layout.preferredHeight: rateLimitErrorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.negativeBackgroundColor

                ColumnLayout {
                    id: rateLimitErrorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + i18n.tr("Rate limited")
                        color: Kirigami.Theme.negativeTextColor
                        font.bold: true
                    }

                    PlasmaComponents.Label {
                        text: i18n.tr("Auto-retry in") + " " + Math.round(root.rateLimitBackoffMs / 60000) + " min"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.negativeTextColor
                    }
                }
            }

            // Transient server/network error - cached data is still shown in the panel
            Rectangle {
                visible: root.hasServerError
                Layout.fillWidth: true
                Layout.preferredHeight: serverErrorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.neutralBackgroundColor

                ColumnLayout {
                    id: serverErrorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + i18n.tr("Service unavailable") + (root.errorStatus > 0 ? " (" + root.errorStatus + ")" : "")
                        color: Kirigami.Theme.neutralTextColor
                        font.bold: true
                    }
                    PlasmaComponents.Label {
                        visible: root.errorDetail !== ""
                        text: root.errorDetail
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.neutralTextColor
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    PlasmaComponents.Label {
                        text: i18n.tr("Showing last known data")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.disabledTextColor
                        font.italic: true
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
                        text: Math.round(root.sessionUsagePercent) + "%"
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
                        text: Math.round(root.weeklyUsagePercent) + "%"
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

            // Per-model breakdown (dynamic — one row per scoped model the API reports)
            Repeater {
                model: root.modelUsages

                RowLayout {
                    id: modelRow
                    required property var modelData
                    Layout.fillWidth: true

                    PlasmaComponents.Label {
                        text: modelRow.modelData.name
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
                            width: parent.width * Math.min(modelRow.modelData.percent / 100, 1)
                            height: parent.height
                            radius: 3
                            color: getUsageColor(modelRow.modelData.percent)
                        }
                    }
                    PlasmaComponents.Label {
                        text: Math.round(modelRow.modelData.percent) + "%"
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            // No model data message
            PlasmaComponents.Label {
                visible: !root.hasModelData
                text: i18n.tr("No model breakdown available")
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
                font.italic: true
            }

            // Rate limit warning
            PlasmaComponents.Label {
                visible: (Plasmoid.configuration.refreshInterval || 5) < 5
                text: "⚠ " + i18n.tr("Values under 5 min may cause rate limiting")
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.neutralTextColor
                font.italic: true
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
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
        id: rateLimitRetryTimer
        interval: root.rateLimitBackoffMs
        running: root.hasRateLimitError
        repeat: true
        onTriggered: {
            console.log("Claude Usage: Backoff retry, interval:", interval/1000, "s")
            loadCredentials()
        }
    }

    // Use retry-after header if available, otherwise fallback to 5min steps (capped at 15min)
    readonly property int rateLimitBackoffMs: root.rateLimitRetryMs > 0
        ? root.rateLimitRetryMs + 10000  // retry-after + 10s buffer
        : Math.min((root.rateLimitRetryCount + 1) * 300000, 900000)

    Timer {
        id: refreshTimer
        interval: {
            if (root.inSlowPollingMode) {
                return Math.max(Plasmoid.configuration.slowPollingInterval || 5, 1) * 60000
            }
            return Math.max(Plasmoid.configuration.refreshInterval || 5, 1) * 60000
        }
        running: !root.hasRateLimitError && !root.inLowPowerMode
        repeat: true
        onTriggered: loadCredentials()
    }

    // Timer to resume polling once the session reset time passes (low power mode)
    Timer {
        id: lowPowerResetTimer
        interval: 60000  // check every minute
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

    function drawCircularProgress(ctx, w, h, percent) {
        var centerX = w / 2
        var centerY = h / 2
        var radius = Math.min(w, h) / 2 - 2
        var lineWidth = 3
        var startAngle = -Math.PI / 2
        var endAngle = startAngle + (2 * Math.PI * Math.min(percent, 100) / 100)

        ctx.reset()

        // Background circle
        ctx.beginPath()
        ctx.arc(centerX, centerY, radius, 0, 2 * Math.PI)
        ctx.strokeStyle = Kirigami.Theme.disabledTextColor
        ctx.globalAlpha = 0.3
        ctx.lineWidth = lineWidth
        ctx.stroke()

        // Progress arc
        if (percent > 0) {
            ctx.beginPath()
            ctx.arc(centerX, centerY, radius, startAngle, endAngle)
            ctx.strokeStyle = getUsageColor(percent)
            ctx.globalAlpha = 1.0
            ctx.lineWidth = lineWidth
            ctx.lineCap = "round"
            ctx.stroke()
        }
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Format a clock time honoring the 12h/24h setting. withSeconds adds ss.
    function formatClockTime(date, withSeconds) {
        if (root.use12HourFormat)
            return Qt.formatTime(date, withSeconds ? "h:mm:ss AP" : "h:mm AP")
        return Qt.formatTime(date, withSeconds ? "hh:mm:ss" : "hh:mm")
    }

    // Format a date + clock time (used for the weekly reset) honoring the setting.
    function formatResetDateTime(date) {
        return Qt.formatDateTime(date, root.use12HourFormat ? "MMM d, h:mm AP" : "MMM d, hh:mm")
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

    // Reload immediately when the configured base folder changes
    Connections {
        target: Plasmoid.configuration
        function onClaudeBaseFolderChanged() {
            console.log("Claude Usage: Base folder changed, reloading")
            refresh()
        }
    }

    // Install icon to system theme for about page
    Plasma5Support.DataSource {
        id: iconInstaller
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) { disconnectSource(sourceName) }
    }

    Component.onCompleted: {
        console.log("Claude Usage: Widget loaded")
        var iconSource = Qt.resolvedUrl("../icons/claude-usage-widget.svg").toString().replace("file://", "")
        iconInstaller.connectSource("bash -c 'ICON_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps && mkdir -p $ICON_DIR && cp \"" + iconSource + "\" $ICON_DIR/claude-usage-widget.svg && chmod 644 $ICON_DIR/claude-usage-widget.svg 2>/dev/null'")
        cacheReader.connectSource("cat $HOME/.local/share/claude-usage-cache.json 2>/dev/null")
        loadCredentials()
    }

    // Only use custom background on desktop, panel keeps default Plasma background
    readonly property bool isOnPanel: Plasmoid.location === PlasmaCore.Types.TopEdge
        || Plasmoid.location === PlasmaCore.Types.BottomEdge
        || Plasmoid.location === PlasmaCore.Types.LeftEdge
        || Plasmoid.location === PlasmaCore.Types.RightEdge

    Plasmoid.backgroundHints: isOnPanel ? PlasmaCore.Types.DefaultBackground : PlasmaCore.Types.NoBackground

    // Custom background with configurable opacity (desktop only)
    Rectangle {
        visible: !root.isOnPanel
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
        opacity: Plasmoid.configuration.backgroundOpacity
        radius: Kirigami.Units.cornerRadius
    }

    Plasmoid.icon: "claude-usage-widget"
    toolTipMainText: i18n.tr("Claude Usage")
    toolTipSubText: {
        var parts = []
        if (Plasmoid.configuration.showSession !== false)
            parts.push(i18n.tr("Session (5hr)") + ": " + Math.round(root.sessionUsagePercent) + "%")
        if (Plasmoid.configuration.showWeekly !== false)
            parts.push(i18n.tr("Weekly (7day)") + ": " + Math.round(root.weeklyUsagePercent) + "%")
        for (var i = 0; i < root.modelUsages.length; i++)
            parts.push(root.modelUsages[i].name + ": " + Math.round(root.modelUsages[i].percent) + "%")
        return parts.join(" | ")
    }
}
