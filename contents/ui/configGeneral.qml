/*
    SPDX-FileCopyrightText: 2025 izll
    SPDX-License-Identifier: GPL-3.0-or-later
*/

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: configPage

    property string cfg_language
    property string cfg_provider
    property string cfg_claudeBaseFolder
    property string cfg_codexBaseFolder
    property int cfg_refreshInterval
    property bool cfg_use12HourFormat
    property bool cfg_lowPowerModeEnabled
    property bool cfg_slowPollingEnabled
    property int cfg_slowPollingInterval
    property int cfg_slowPollingThreshold
    property string cfg_panelLayout
    property bool cfg_showIcon
    property string cfg_panelStyle
    property bool cfg_showSession
    property bool cfg_showWeekly
    property bool cfg_showTopModel
    property string cfg_baseUrl
    property string cfg_apiKey
    property double cfg_backgroundOpacity

    // Translation helper
    Translations {
        id: trans
        currentLanguage: cfg_language || "system"
    }

    function tr(text) { return trans.tr(text); }

    readonly property var languageValues: [
        "system", "en_US", "hu_HU", "de_DE", "fr_FR", "es_ES",
        "it_IT", "pt_BR", "ru_RU", "pl_PL", "nl_NL", "tr_TR",
        "ja_JP", "ko_KR", "zh_CN", "zh_TW"
    ]

    readonly property var languageNames: [
        tr("System default"), "English", "Magyar", "Deutsch",
        "Français", "Español", "Italiano", "Português (Brasil)",
        "Русский", "Polski", "Nederlands", "Türkçe",
        "日本語", "한국어", "简体中文", "繁體中文"
    ]

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: languageCombo
            Kirigami.FormData.label: tr("Language:")

            model: languageNames
            currentIndex: languageValues.indexOf(cfg_language)

            onActivated: index => {
                cfg_language = languageValues[index]
            }
        }

        QQC2.ComboBox {
            id: providerCombo
            Kirigami.FormData.label: tr("Provider:")
            model: ["Claude", "OpenAI Codex"]
            currentIndex: cfg_provider === "codex" ? 1 : 0
            onActivated: index => { cfg_provider = index === 1 ? "codex" : "claude" }
        }

        QQC2.Label {
            Layout.fillWidth: true
            text: tr("Each widget instance tracks one account. Add another instance for a second subscription.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        QQC2.TextField {
            id: baseFolderField
            visible: cfg_provider !== "codex"
            Kirigami.FormData.label: tr("Claude base folder:")
            Layout.fillWidth: true
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
            text: cfg_claudeBaseFolder
            placeholderText: "$HOME/.claude"
            onTextChanged: cfg_claudeBaseFolder = text
        }

        QQC2.Label {
            visible: cfg_provider !== "codex"
            Layout.fillWidth: true
            text: tr("Folder containing .credentials.json (e.g. $HOME/.claude-work for a second account)")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        QQC2.TextField {
            id: codexFolderField
            visible: cfg_provider === "codex"
            Kirigami.FormData.label: tr("Codex base folder:")
            Layout.fillWidth: true
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
            text: cfg_codexBaseFolder
            placeholderText: "$HOME/.codex"
            onTextChanged: cfg_codexBaseFolder = text
        }

        QQC2.Label {
            visible: cfg_provider === "codex"
            Layout.fillWidth: true
            text: tr("Folder containing auth.json created by 'codex login'")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Kirigami.FormData.label: tr("Refresh interval:")

            QQC2.SpinBox {
                id: refreshSpinBox
                from: 1
                to: 999
                stepSize: 1
                value: cfg_refreshInterval

                onValueChanged: {
                    cfg_refreshInterval = value
                }
            }

            QQC2.Label {
                text: tr("minutes")
            }
        }

        QQC2.Label {
            visible: cfg_refreshInterval < 5
            text: "⚠ " + tr("Values under 5 min may cause rate limiting")
            color: Kirigami.Theme.negativeTextColor
            font.italic: true
            Layout.fillWidth: true
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: tr("Time format:")
            model: [tr("24-hour"), tr("12-hour (AM/PM)")]
            currentIndex: cfg_use12HourFormat ? 1 : 0
            onActivated: index => { cfg_use12HourFormat = index === 1 }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: tr("Power Saving")
        }

        QQC2.CheckBox {
            id: lowPowerCheckBox
            Kirigami.FormData.label: tr("Low power mode:")
            text: tr("Pause polling when session hits 100%")
            checked: cfg_lowPowerModeEnabled
            onCheckedChanged: cfg_lowPowerModeEnabled = checked
        }

        QQC2.CheckBox {
            id: slowPollingCheckBox
            Kirigami.FormData.label: tr("Slow polling:")
            text: tr("Reduce poll frequency when usage unchanged")
            checked: cfg_slowPollingEnabled
            onCheckedChanged: cfg_slowPollingEnabled = checked
        }

        RowLayout {
            Kirigami.FormData.label: tr("Slow poll interval:")
            enabled: cfg_slowPollingEnabled

            QQC2.SpinBox {
                id: slowPollingSpinBox
                from: 1
                to: 999
                stepSize: 1
                value: cfg_slowPollingInterval

                onValueChanged: {
                    cfg_slowPollingInterval = value
                }
            }

            QQC2.Label {
                text: tr("minutes")
            }
        }

        RowLayout {
            Kirigami.FormData.label: tr("Unchanged polls threshold:")
            enabled: cfg_slowPollingEnabled

            QQC2.SpinBox {
                id: thresholdSpinBox
                from: 1
                to: 99
                stepSize: 1
                value: cfg_slowPollingThreshold

                onValueChanged: {
                    cfg_slowPollingThreshold = value
                }
            }

            QQC2.Label {
                text: tr("consecutive polls")
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: tr("Panel display")
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: tr("Layout:")
            model: [tr("Horizontal"), tr("Vertical")]
            currentIndex: cfg_panelLayout === "vertical" ? 1 : 0
            onCurrentIndexChanged: cfg_panelLayout = currentIndex === 1 ? "vertical" : "horizontal"
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: tr("Icon:")
            text: tr("Show provider icon")
            checked: cfg_showIcon
            onCheckedChanged: cfg_showIcon = checked
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: tr("Style:")
            model: [tr("Text"), tr("Circular"), tr("Bar")]
            currentIndex: cfg_panelStyle === "circular" ? 1 : cfg_panelStyle === "bar" ? 2 : 0
            onCurrentIndexChanged: {
                var styles = ["text", "circular", "bar"]
                cfg_panelStyle = styles[currentIndex]
            }
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: tr("Show in panel:")
            text: tr("Session (5hr)")
            checked: cfg_showSession
            onCheckedChanged: cfg_showSession = checked
        }

        QQC2.CheckBox {
            text: tr("Weekly (7day)")
            checked: cfg_showWeekly
            onCheckedChanged: cfg_showWeekly = checked
        }

        QQC2.CheckBox {
            visible: cfg_provider !== "codex"
            text: tr("Top model")
            checked: cfg_showTopModel
            onCheckedChanged: cfg_showTopModel = checked
        }

        RowLayout {
            Kirigami.FormData.label: tr("Background opacity (desktop):")

            QQC2.Slider {
                id: opacitySlider
                from: 0.0
                to: 1.0
                stepSize: 0.05
                value: cfg_backgroundOpacity
                Layout.preferredWidth: Kirigami.Units.gridUnit * 10

                onMoved: {
                    cfg_backgroundOpacity = value
                }
            }

            QQC2.Label {
                text: Math.round(opacitySlider.value * 100) + "%"
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2
            }
        }

        Kirigami.Separator {
            visible: cfg_provider !== "codex"
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: tr("Custom API (optional)")
        }

        QQC2.TextField {
            id: baseUrlField
            visible: cfg_provider !== "codex"
            Kirigami.FormData.label: tr("Base URL:")
            placeholderText: "https://api.anthropic.com"
            text: cfg_baseUrl
            onTextChanged: cfg_baseUrl = text
            Layout.fillWidth: true
        }

        QQC2.Label {
            visible: cfg_provider !== "codex"
            text: tr("Leave empty to use ~/.claude/.credentials.json (default)")
            font.italic: true
            opacity: 0.7
            Layout.fillWidth: true
        }

        QQC2.TextField {
            id: apiKeyField
            visible: cfg_provider !== "codex"
            Kirigami.FormData.label: tr("API key:")
            placeholderText: "sk-ant-..."
            text: cfg_apiKey
            echoMode: TextInput.Password
            enabled: cfg_baseUrl !== ""
            onTextChanged: cfg_apiKey = text
            Layout.fillWidth: true
        }
    }
}
