#Requires AutoHotkey 2.0
#SingleInstance Force
Persistent

; --- Optional libs you still use elsewhere ---
#Include "_jxon.ahk"
;#Include "lib\WebView2.ahk" ; (not used here; comment out to speed up load)

; ====================================================
; Config
; ====================================================
API_Key := "lm-studio"
API_URL := "http://127.0.0.1:1234/v1/chat/completions"

Model_Fast  := "qwen/qwen3-30b-a3b-2507"     ; smaller/faster
Model_Best  := "openai/gpt-oss-20b"          ; larger/slower

; Per-model default generation params
ModelParams := Map(
    Model_Fast, Map(  ; smaller/faster
        "temperature",       0.4,
        "top_p",             0.85,
        "top_k",             30,
        "min_p",             0.05,
        "presence_penalty",  0.0
    ),
    Model_Best, Map(   ; larger/slower (better)
        "temperature",       0.7,
        "top_p",             0.90,
        "top_k",             40,
        "min_p",             0.00,
        "presence_penalty",  1.0
    )
)

; Optional global fallbacks if a model isn't in ModelParams
llm_temperature       := 0.7
llm_top_k             := 20
llm_min_p             := 0.00
llm_top_p             := 0.80
llm_presence_penalty  := 1.0

; ====================================================
; Tray & Suspend UI
; ====================================================
TraySetIcon("IconOn.ico")
A_TrayMenu.Delete
A_TrayMenu.Add("&Debug", (*) => ListLines())
A_TrayMenu.Add("&Reload Script", (*) => Reload())
A_TrayMenu.Add("E&xit", (*) => ExitApp())
A_IconTip := "LLM AutoHotkey Utility"

suspendGui := Gui()
suspendGui.AddText("cWhite", "LLM AutoHotkey Utility Suspended")
suspendGui.BackColor := "0x7F00FF"
suspendGui.Opt("-Caption +Owner -SysMenu +AlwaysOnTop")

Toggle_Suspend(*) {
    Suspend -1
    if A_IsSuspended {
        TraySetIcon("IconOff.ico",, 1)
        A_IconTip := "LLM AutoHotkey Utility - Suspended (CapsLock+` to resume)"
        suspendGui.Show("AutoSize x885 y35 NA")
    } else {
        TraySetIcon("IconOn.ico")
        A_IconTip := "LLM AutoHotkey Utility"
        suspendGui.Hide()
    }
}

#SuspendExempt
CapsLock & `:: {
    KeyWait "CapsLock","L"
    KeyWait "``","L"
    SetCapsLockState "Off"
    Toggle_Suspend()
}

; ====================================================
; Actions (system prompts)
; ====================================================
ActionPrompts := Map(
  "rephrase",        "Formuliere den folgenden Text oder Absatz um, um Klarheit, Konkretheit und natürlichen Sprachfluss sicherzustellen. Die Überarbeitung soll Tonfall, Stil, Sprache und Formatierung des ursprünglichen Textes beibehalten. Teile den Text (wenn möglich) in Paragraphen auf, um die Lesbarkeit zu verbessern. Behebe außerdem Grammatik- und Rechtschreibfehler. Die Sprache bleibt gleich der des ursprünglichen Textes und im Zweifelsfall Deutsch.",
  "pro",             "Formuliere den folgenden Text oder Absatz auf professionellen, freundlichen Ton und Stil um und formuliere ihn weiter aus (ohne leere Ausschweifungen), damit Klarheit, Konkretheit und natürlicher Sprachfluss sichergestellt werden. Die Sprache bleibt gleich der des ursprünglichen Textes und im Zweifelsfall Deutsch. Teile den Text (wenn möglich) in Paragraphen auf, um die Lesbarkeit zu verbessern.",
  "follow",          "Beantworte folgende Frage, bzw. folge folgenden Anweisungen:",
  "reply",           "Formuliere eine Antwort auf folgende Nachricht:",
  "to_en",           "Generate an English translation for the following text or paragraph, ensuring accurate meaning and preserving tone, style, and formatting. Split into paragraphs if it helps readability. Don't add any comments or explanations—only the translation:",
  "to_de",           "Generate a German translation for the following text or paragraph, ensuring accurate meaning and preserving tone, style, and formatting. Split into paragraphs if helpful. Do not add any comments, warnings or explanations—only reply with the translation:",
  "todos",           "Suche nach ToDos und stelle sie stichwortartig in Listenform dar (inkl. Zuordnung, sortiert nach Person/Unternehmen, falls vorhanden):",
  "define",          "Definiere Folgendes prägnant und verständlich:",
  "pros_cons",       "Vorteile, Nachteile und eine kurze Empfehlung zu Folgendem:"
)

; ====================================================
; Menus
; ====================================================
MenuFast := Menu()
MenuBest := Menu()

AddMenuItems(menu, model, isFast := false) {
    menu.Add("&0 - Formuliere um - gleicher Stil",         (*) => ExecuteAction(model, "rephrase", isFast))
    menu.Add("&1 - Formuliere ausführlicher, professioneller, freundlicher", (*) => ExecuteAction(model, "pro", isFast))
    menu.Add("&2 - Folge Anweisungen",                     (*) => ExecuteAction(model, "follow", isFast))
    menu.Add("&3 - Nachricht beantworten",                 (*) => ExecuteAction(model, "reply", isFast))
    menu.Add("&4 - Übersetze -> Englisch",                 (*) => ExecuteAction(model, "to_en", isFast))
    menu.Add("&5 - Übersetze -> Deutsch",                  (*) => ExecuteAction(model, "to_de", isFast))
    ; menu.Add("&6 - Fasse zusammen",                     (*) => ExecuteAction(model, "summ", isFast)) ; (kept out by request)
    menu.Add("&7 - ToDos auflisten",                       (*) => ExecuteAction(model, "todos", isFast))
    menu.Add("&8 - Erkläre / Definition",                  (*) => ExecuteAction(model, "define", isFast))
    menu.Add("&9 - Vorteile / Nachteile",                  (*) => ExecuteAction(model, "pros_cons", isFast))
}
AddMenuItems(MenuFast, Model_Fast, true)
AddMenuItems(MenuBest, Model_Best, false)

; Hotkeys to open menus
^+l:: MenuFast.Show()    ; Ctrl+Shift+L  -> fast model
^+ö:: MenuBest.Show()    ; Ctrl+Shift+Ö  -> best model (DE layout)

; ====================================================
; Core execution
; ====================================================

global __inflight := false
global __abort := false

; Press Esc to cancel an in-flight request
Esc::
{
    if __inflight {
        __abort := true
        ToolTip "Aborting..."
        SetTimer () => ToolTip(), -1200
    }
}

ExecuteAction(model, actionKey, isFastModel := false) {
    if !ActionPrompts.Has(actionKey) {
        ToolTip "Unknown action."
        SetTimer () => ToolTip(), -1200
        return
    }

    ; 1) Capture current selection to clipboard (with full backup)
    clipBackup := ClipboardAll()
    savedCF := DllCall("RegisterClipboardFormat", "Str","Preferred DropEffect", "UInt")
    A_Clipboard := ""
    Send "^c"
    if !ClipWait(2) {
        ; fallback: keep whatever user had—don’t overwrite
        ToolTip "Copy failed (no selection?)"
        SetTimer () => ToolTip(), -1500
        Clipboard := clipBackup
        return
    }
    selText := A_Clipboard

    ; 2) Build prompts
    sys := ActionPrompts[actionKey]
    if isFastModel {
        ; keep your “/nothink” trick for the fast model
        sys .= " /nothink"
    }
    user := selText

    ; 3) Call API
    __inflight := true, __abort := false
    status := StatusTextFor(actionKey)
    StartLoading(status)

    resp := ""
    try {
        ; pick per-model defaults (fallback to globals if missing)
        cfg := ModelParams.Has(model)
            ? ModelParams[model]
            : Map("temperature", llm_temperature
                , "top_p", llm_top_p
                , "top_k", llm_top_k
                , "min_p", llm_min_p
                , "presence_penalty", llm_presence_penalty)
        resp := SendChatCompletion(API_URL, API_Key, model, sys, user
            , cfg["temperature"], cfg["top_p"], cfg["top_k"], cfg["min_p"], cfg["presence_penalty"])
    } catch as e {
        StopLoading()
        __inflight := false
        ToolTip "Error: " e.Message
        SetTimer () => ToolTip(), -3500
        Clipboard := clipBackup
        return
    }
    StopLoading()
    __inflight := false
    if __abort {
        ToolTip "Aborted."
        SetTimer () => ToolTip(), -1200
        Clipboard := clipBackup
        return
    }

    if !resp {
        ToolTip "No response from model."
        SetTimer () => ToolTip(), -2000
        Clipboard := clipBackup
        return
    }

    ; 4) Paste response over selection, then restore original clipboard
    A_Clipboard := resp
    ; Small pause to let clipboard settle
    ClipWait 1
    Send "^v"
    Sleep 80
    Clipboard := clipBackup
    ; Optional UX: brief preview tooltip
    ToolTip "✔️ Done"
    SetTimer () => ToolTip(), -900
}

StatusTextFor(actionKey) {
    switch actionKey {
        case "rephrase":   return "Formuliere um..."
        case "pro":        return "Formuliere ausführlicher..."
        case "follow":     return "Antworte..."
        case "reply":      return "Antwort wird formuliert..."
        case "to_en":      return "Übersetze nach Englisch..."
        case "to_de":      return "Übersetze nach Deutsch..."
        case "todos":      return "Suche ToDos..."
        case "define":     return "Definiere..."
        case "pros_cons":  return "Denke nach..."
        default:           return "Arbeite..."
    }
}

; ====================================================
; HTTP + JSON (fixed try/catch blocks)
; ====================================================
SendChatCompletion(apiUrl, apiKey, model, sysPrompt, userPrompt
    , temperature := 0.7, top_p := 0.8, top_k := 20, min_p := 0.0, presence_penalty := 1.0) {

    if __abort
        throw Error("Aborted")

    req := ComObject("WinHTTP.WinHTTPRequest.5.1")
    req.Open("POST", apiUrl, true) ; async
    req.SetRequestHeader("Content-Type", "application/json")
    req.SetRequestHeader("Authorization", "Bearer " apiKey)

    ; Build OpenAI-compatible JSON
    json := "{"
        . '"model":"'        JsonEscape(model) '",'
        . '"messages":['
            . '{"role":"system","content":"' JsonEscape(sysPrompt) '"},'
            . '{"role":"user","content":"'   JsonEscape(userPrompt) '"}'
        . '],'
        . '"temperature":'      temperature ','
        . '"top_p":'            top_p ','
        . '"min_p":'            min_p ','
        . '"top_k":'            top_k ','
        . '"presence_penalty":' presence_penalty
        . "}"

    req.Send(json)

    ; poll for readiness with abort support (~20s max)
    gotResp := false
    loop 2000 {
        if __abort {
            try {
                req.Abort()
            } catch as e {
                ; ignore abort errors
            }
            throw Error("Aborted")
        }
        try {
            ; Accessing Status before ready throws -> caught below
            if req.Status {
                gotResp := true
                break
            }
        } catch as e {
            ; not ready yet
        }
        Sleep 10
    }
    if !gotResp {
        try {
            req.Abort()
        } catch as e {
            ; ignore abort errors
        }
        throw Error("Timeout connecting to LLM API")
    }

    ; read body
    body := ""
    try {
        body := req.ResponseText
    } catch as e {
        throw Error("No response body")
    }

    ; parse with JXON (block try/catch)
    respObj := {}
    try {
        respObj := Jxon_Load(&body)
    } catch as e {
        ; fallback: naive extraction
        return ExtractTextFromChoices(body)
    }

    if respObj.Has("error") {
        errMsg := respObj.error.Has("message") ? respObj.error.message : "Unknown API error"
        throw Error(errMsg)
    }

    if respObj.Has("choices") {
        try {
            return respObj.choices[1].message.content
        } catch as e {
            ; structure not as expected -> fallback
        }
    }

    ; final fallback
    return ExtractTextFromChoices(body)
}

ExtractTextFromChoices(jsonText) {
    m := StrReplace(jsonText, "`r")
    m := StrReplace(m, "`n")
    if RegExMatch(m, '"content"\s*:\s*"((?:\\.|[^"\\])*)"', &out) {
        return StrReplace(out[1], '\"', '"')
    }
    return ""
}

JsonEscape(s) {
    ; Escape backslashes
    s := StrReplace(s, "\", "\\")
    ; Escape double quotes safely using variables
    quote := Chr(34)       ; the " character
    backslash := "\"
    s := StrReplace(s, quote, backslash . quote)
    ; Remove carriage returns
    s := StrReplace(s, "`r", "")
    ; Replace newlines with literal \n
    s := StrReplace(s, "`n", "\n")
    return s
}

; ====================================================
; Loading tooltip (fixed: named timer, global message)
; ====================================================
global __loadingStage := 0
global __loadingMsg   := ""
global __loadingOn    := false

StartLoading(msg := "Working...") {
    global __loadingStage, __loadingMsg, __loadingOn
    __loadingMsg   := msg
    __loadingStage := 0
    __loadingOn    := true
    SetTimer ShowLoading, 250
}

StopLoading() {
    global __loadingOn
    __loadingOn := false
    SetTimer ShowLoading, 0
    ToolTip
}

ShowLoading() {
    global __loadingStage, __loadingMsg, __loadingOn
    if !__loadingOn {
        return
    }
    dots := ""
    Loop __loadingStage
        dots .= "."
    ToolTip(__loadingMsg . dots)
    __loadingStage := Mod(__loadingStage + 1, 4)
}
