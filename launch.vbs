' Starts the Claude usage widget without a console window.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & dir & "\ClaudeUsageWidget.ps1""", 0, False
