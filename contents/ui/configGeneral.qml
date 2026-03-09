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
    property int cfg_refreshInterval
    property bool cfg_lowPowerModeEnabled
    property bool cfg_slowPollingEnabled
    property int cfg_slowPollingInterval
    property int cfg_slowPollingThreshold

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
    }
}
