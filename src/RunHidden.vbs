' Session Recovery helper
' Starts a PowerShell script with no visible window.
'
' Usage: wscript.exe RunHidden.vbs [save|watch|tray|tray-monitor|restore]
'   save          take one snapshot (default)
'   watch         keep taking snapshots every few minutes
'   tray          run the background tray app and take snapshots
'   tray-monitor  run the tray app without owning the snapshot timer
'   restore       show the restore prompt after a logon

Option Explicit

Dim shell, fso, here, mode, scriptPath, command, powershellPath

If WScript.Arguments.Count > 0 Then
    mode = LCase(WScript.Arguments(0))
Else
    mode = "save"
End If

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

Select Case mode
    Case "watch"
        scriptPath = fso.BuildPath(here, "Watch-Session.ps1")
    Case "tray", "tray-monitor"
        scriptPath = fso.BuildPath(here, "Tray-SessionRecovery.ps1")
    Case "restore"
        scriptPath = fso.BuildPath(here, "Restore-Session.ps1")
    Case Else
        scriptPath = fso.BuildPath(here, "Save-Session.ps1")
End Select

If Not fso.FileExists(scriptPath) Then
    WScript.Quit 1
End If

powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
command = """" & powershellPath & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"

Select Case mode
    Case "restore"
        command = command & " -StartupDelaySeconds 20"
    Case "tray-monitor"
        command = command & " -MonitorOnly"
    Case "tray"
        ' no extra arguments
    Case "watch"
        ' no extra arguments
    Case Else
        command = command & " -Quiet"
End Select

shell.Run command, 0, False
