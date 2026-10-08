' DeepSeek Token Usage - balance helper watchdog.
'
' The helper only does something while Codex Desktop is running, so this
' watchdog starts it when Codex comes up and stops it when Codex exits. It is
' hosted by wscript.exe (GUI subsystem), so it never opens a console window
' and it keeps working after you close any terminal.
'
' Autostart: press Win+R, run "shell:startup", and drop a shortcut to this
' file into the folder that opens.
'
' Optional environment variables:
'   DSTU_NODE    full path to node.exe (default: first node found on PATH)
'   DSTU_HELPER  full path to dstu-helper.mjs (default: next to this file)
' An environment variable can also be set from the command line, e.g.
'   set DSTU_BALANCE_URL=http://127.0.0.1:<port>/<path>  (only if you run your
'   own balance proxy; the helper also works with just an API key)

Option Explicit

Dim sh, fso, wmi, helperPath, nodePath, helperMissingNoted
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set wmi = GetObject("winmgmts:\\.\root\cimv2")

helperPath = ResolveHelper()
nodePath = ResolveNode()

helperMissingNoted = False

' Never pop a modal box here: this script runs hidden, so a dialog would just
' hang invisibly. Write the reason to start-helper.log and quit instead.
If Not fso.FileExists(helperPath) Then
    LogLine "dstu-helper.mjs not found, nothing to watch: " & helperPath
    WScript.Quit 1
End If

Function EnvValue(name)
    Dim value
    value = ""
    On Error Resume Next
    value = sh.Environment("PROCESS")(name)
    If Err.Number <> 0 Then value = ""
    On Error GoTo 0
    If IsNull(value) Then value = ""
    EnvValue = Trim(value)
End Function

Function ResolveHelper()
    Dim override
    override = EnvValue("DSTU_HELPER")
    If Len(override) > 0 And fso.FileExists(override) Then
        ResolveHelper = override
    Else
        ResolveHelper = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "dstu-helper.mjs")
    End If
End Function

' node.exe is either given by DSTU_NODE or taken from PATH, so nothing here
' depends on where Node.js happens to be installed on this machine.
Function ResolveNode()
    Dim override, output, lines, shell
    override = EnvValue("DSTU_NODE")
    If Len(override) > 0 And fso.FileExists(override) Then
        ResolveNode = override
        Exit Function
    End If
    ' The installer writes the node it picked (often a portable copy it fetched
    ' itself) into node-path.txt next to the helper; prefer that.
    Dim savedPath, savedFile
    savedFile = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "node-path.txt")
    If fso.FileExists(savedFile) Then
        On Error Resume Next
        Dim stream
        Set stream = fso.OpenTextFile(savedFile, 1)
        savedPath = Trim(stream.ReadLine())
        stream.Close
        On Error GoTo 0
        If Len(savedPath) > 0 And fso.FileExists(savedPath) Then
            ResolveNode = savedPath
            Exit Function
        End If
    End If
    output = ""
    On Error Resume Next
    Set shell = sh.Exec("%ComSpec% /c where node 2>nul")
    If Err.Number = 0 Then
        Do While shell.Status = 0
            WScript.Sleep 50
        Loop
        output = Trim(shell.StdOut.ReadAll())
    End If
    On Error GoTo 0
    If Len(output) > 0 Then
        lines = Split(Replace(output, vbLf, vbCr), vbCr)
        If fso.FileExists(Trim(lines(0))) Then
            ResolveNode = Trim(lines(0))
            Exit Function
        End If
    End If
    ' PATH may not carry node when this runs from the Startup folder (nvm-windows,
    ' Volta, Scoop, fnm, manual installs). Try the usual homes; all of them are
    ' plain file paths, so x64 and ARM64 Windows work the same way.
    Dim homes, i, candidate
    homes = Array( _
        "%ProgramFiles%\nodejs\node.exe", _
        "%ProgramFiles(x86)%\nodejs\node.exe", _
        "%LOCALAPPDATA%\Programs\nodejs\node.exe", _
        "%APPDATA%\nvm\node.exe", _
        "%LOCALAPPDATA%\Volta\bin\node.exe", _
        "%LOCALAPPDATA%\fnm_multishells\node.exe", _
        "%USERPROFILE%\scoop\shims\node.exe", _
        "%ProgramData%\chocolatey\bin\node.exe", _
        "C:\nodejs\node.exe")
    For i = 0 To UBound(homes)
        candidate = sh.ExpandEnvironmentStrings(homes(i))
        If fso.FileExists(candidate) Then
            ResolveNode = candidate
            Exit Function
        End If
    Next
    ResolveNode = "node.exe"
End Function

Function IsCodexRunning()
    Dim procs, p
    IsCodexRunning = False
    Set procs = wmi.ExecQuery("SELECT Name FROM Win32_Process WHERE Name='ChatGPT.exe' OR Name='codex.exe' OR Name='codex-plus-plus.exe' OR Name='CodexPlusPlus.exe'")
    For Each p In procs
        IsCodexRunning = True
        Exit Function
    Next
End Function

Function IsHelperRunning()
    Dim procs, p
    IsHelperRunning = False
    Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='node.exe'")
    For Each p In procs
        If Not IsNull(p.CommandLine) Then
            If InStr(1, p.CommandLine, "dstu-helper.mjs", 1) > 0 Then
                IsHelperRunning = True
                Exit Function
            End If
        End If
    Next
End Function

Sub StopHelper()
    Dim procs, p
    Set procs = wmi.ExecQuery("SELECT * FROM Win32_Process WHERE Name='node.exe'")
    For Each p In procs
        If Not IsNull(p.CommandLine) Then
            If InStr(1, p.CommandLine, "dstu-helper.mjs", 1) > 0 Then
                p.Terminate()
            End If
        End If
    Next
End Sub

' One line per state change; the log is trimmed at 100 KB.
Sub LogLine(message)
    Dim file, stream, logPath
    On Error Resume Next
    logPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "start-helper.log")
    If fso.FileExists(logPath) Then
        Set file = fso.GetFile(logPath)
        If file.Size > 102400 Then
            Set stream = file.OpenAsTextStream(2)
            stream.Close
        End If
    End If
    Set stream = fso.OpenTextFile(logPath, 8, True)
    stream.WriteLine Now & "  " & message
    stream.Close
    If Err.Number <> 0 Then Err.Clear
    On Error GoTo 0
End Sub

Do While True
    If Not fso.FileExists(helperPath) Then
        ' Antivirus or a manual cleanup can wipe the install folder. Do not spawn
        ' node every 3 seconds against a missing file: note it once and wait for
        ' the file to come back.
        If Not helperMissingNoted Then
            LogLine "helper file missing, waiting for it to come back: " & helperPath
            helperMissingNoted = True
        End If
    Else
        If helperMissingNoted Then
            LogLine "helper file is back, starting it again: " & helperPath
            helperMissingNoted = False
        End If
        If IsCodexRunning() Then
            If Not IsHelperRunning() Then
                sh.CurrentDirectory = fso.GetParentFolderName(helperPath)
                sh.Run """" & nodePath & """ """ & helperPath & """", 0, False
            End If
        Else
            If IsHelperRunning() Then
                StopHelper()
            End If
        End If
    End If
    WScript.Sleep 3000
Loop
