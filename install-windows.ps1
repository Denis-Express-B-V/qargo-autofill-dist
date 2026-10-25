# Qargo Autofill - install / repair / update for Windows 10 and 11 (64-bit). No administrator rights needed.
#
# Run it: press the Windows key + R, paste this one line, press Enter:
#   powershell -nop -exec Bypass -Command "$env:QARGO_SITE='<site code>';try{irm https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main/install-windows.ps1|iex}catch{Write-Host $_;Read-Host 'Not installed. Press Enter'}"
# (the try/catch is for the download of this file itself: without it the window would close at once when it fails)
# The installation page puts the site code in the line (its link ends in #s=<site code>): the id of the secret gist
# that holds the site profile, the names the public release only has as placeholders (qargo_launcher.fill_in_site).
# -nop / -exec are -NoProfile / -ExecutionPolicy, short so that the line with the code fits the Run box (259).
#
# Running it again repairs or updates the installation; the data folder is never touched.
# Everything goes to %LOCALAPPDATA%\QargoAutofill, plus "Qargo Autofill.lnk" on the Desktop and in the Start menu.
# Nothing else is changed: no PATH, no registry entry, no setting of Windows, no execution policy.
#
# Written for Windows PowerShell 5.1 and for "iex": ASCII only, no param() block, no $PSScriptRoot.
# Test overrides (environment): QARGO_HOME, QARGO_DIST_URL, QARGO_CHANNEL, QARGO_SHORTCUT_DIRS (';' separated),
# QARGO_NO_OPEN=1 (do not start the program), QARGO_NONINTERACTIVE=1 (no "Press Enter"; exit code 0 = installed,
# 1 = failed, 2 = blocked by application control, 3 = PowerShell is restricted on this PC).

# ---- Preflight. Only cmdlets, plain variables and string comparison up to the check below: this part must also
# ---- work in Constrained Language Mode (company-managed PCs), where any .NET call would end in a red error.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'    # the 5.1 progress bar makes Invoke-WebRequest many times slower
$QaLanguageMode = $ExecutionContext.SessionState.LanguageMode
if ("$QaLanguageMode" -ne 'FullLanguage') {
    # On a home PC it can be Smart App Control that restricts PowerShell: then there is no organisation to blame,
    # and the owner has a choice. Reading the registry with a cmdlet is allowed in this mode.
    $QaSac = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
    $QaSacState = ''
    if ($QaSac) { $QaSacState = "$($QaSac.VerifiedAndReputablePolicyState)" }
    Write-Host ''
    Write-Host 'Qargo Autofill can NOT be installed on this PC.' -ForegroundColor Red
    Write-Host "Windows only allows restricted commands here (PowerShell language mode: $QaLanguageMode)."
    if ($QaSacState -eq '1') {
        Write-Host 'The Windows protection "Smart App Control" is switched on here.'
        Write-Host 'It stops every program that Microsoft does not know yet. This program is one of those.'
        Write-Host 'The owner of this PC has two choices:'
        Write-Host '  1. Leave Smart App Control on. Then Qargo Autofill cannot be used on this PC.'
        Write-Host '  2. Switch Smart App Control off:'
        Write-Host '       Start > Windows Security > App & browser control > Smart App Control settings > Off'
        Write-Host '     and then run the same line again. Switching it on again later usually works, but not always.'
        Write-Host 'This is the decision of the owner of the PC. It lowers a protection of Windows.'
    } else {
        Write-Host 'That is a rule of the organisation that manages this PC. It is not a fault of the PC or of the program.'
    }
    Write-Host 'Nothing was installed and nothing was changed.'
    Write-Host 'Please call the person who sent you the link.'
    if ($env:QARGO_NONINTERACTIVE) { exit 3 }
    Read-Host 'Press Enter to close this window' | Out-Null
    return
}

function Install-QargoAutofill {
    $AppName   = 'Qargo Autofill'
    $BaseUrl   = 'https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main'              # make_release.sh fills in the public address
    $Channel   = 'stable'
    if ($env:QARGO_CHANNEL) { $Channel = $env:QARGO_CHANNEL }
    $DistUrl   = "$BaseUrl/$Channel"
    if ($env:QARGO_DIST_URL) { $DistUrl = $env:QARGO_DIST_URL }
    $UvVersion = '0.13.0'                           # pinned, with its checksum
    $UvZip     = 'uv-x86_64-pc-windows-msvc.zip'    # x64 on purpose: also runs on Windows 11 ARM (emulation)
    $UvSha256  = '088962f9e7b7bd9ea740c04c650b2a21c8928c345bd99ac24350dc924dba656c'
    $PyRequest = 'cpython-3.13-windows-x86_64-none' # pinned: uv 0.13 would otherwise pick Python 3.15
    $Root      = Join-Path $env:LOCALAPPDATA 'QargoAutofill'
    if ($env:QARGO_HOME) { $Root = $env:QARGO_HOME }
    $Site      = "$env:QARGO_SITE"
    if ($Site -and $Site -cnotmatch '^[0-9a-f]{20,40}$') { throw 'The site code in this line is not valid. Copy the line from the page you were sent again.' }
    # a repair keeps the code it was installed with (state.json); a first install without one would fail at step 3
    $StateFile = Join-Path $Root 'app\state.json'
    if (-not $Site -and -not ((Test-Path -LiteralPath $StateFile) -and (Select-String -LiteralPath $StateFile -Pattern '"site"' -SimpleMatch -Quiet))) {
        throw 'This line has no site code. Open the link you were sent (it ends in #s=...) and copy the line from that page.'
    }

    function Say {
        param([string]$Text)
        Write-Host ''
        Write-Host "==> $Text" -ForegroundColor Cyan
    }

    function Invoke-Native {
        # Run a console program, show its output, give back its exit code and its text.
        # In 5.1 a native stderr line becomes an error record when redirected; with 'Stop' that would abort the script.
        # A program that Windows refuses to start at all (application control) throws instead: that is caught here too.
        param([string]$Exe, [string[]]$ArgList, [switch]$Quiet)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $lines = New-Object System.Collections.Generic.List[string]
        $code = 0
        try {
            & $Exe @ArgList 2>&1 | ForEach-Object {
                $line = "$_"
                $lines.Add($line)
                if (-not $Quiet) { Write-Host "    $line" }
            }
            $code = $LASTEXITCODE
        } catch {
            $lines.Add("$($_.Exception.Message)")
            if (-not $Quiet) { Write-Host "    $($_.Exception.Message)" }
            $e = $_.Exception                       # the message is in the language of Windows; the number is not
            while ($e) {
                if ($e -is [System.ComponentModel.Win32Exception]) { $lines.Add("WinError $($e.NativeErrorCode)") }
                $e = $e.InnerException
            }
            $code = -1
        } finally {
            $ErrorActionPreference = $old
        }
        return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n") }
    }

    function Get-SacState {
        # Smart App Control: 0 = off, 1 = on, 2 = evaluation, -1 = not there (Windows 10) or not readable
        $p = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
        if ($p -and ($null -ne $p.VerifiedAndReputablePolicyState)) { return [int]$p.VerifiedAndReputablePolicyState }
        return -1
    }

    function Stop-Blocked {
        # Windows refused to run a part of the program. Say what that means and what the choices are; no icon is made.
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Yellow
        Write-Host '  Windows is blocking Qargo Autofill on this PC.' -ForegroundColor Yellow
        Write-Host '============================================================' -ForegroundColor Yellow
        if ((Get-SacState) -eq 1) {
            Write-Host 'The Windows protection "Smart App Control" is switched on here.'
            Write-Host 'It stops every program that Microsoft does not know yet. This program is one of those.'
            Write-Host 'Windows has no way to allow one single program.'
            Write-Host ''
            Write-Host 'The owner of this PC has two choices:'
            Write-Host '  1. Leave Smart App Control on. Then Qargo Autofill cannot be used on this PC.'
            Write-Host '  2. Switch Smart App Control off:'
            Write-Host '       Start > Windows Security > App & browser control > Smart App Control settings > Off'
            Write-Host '     and then run the same line again.'
            Write-Host '     Switching it on again later usually works, but not always:'
            Write-Host '     on some PCs Windows must be reset before it can be switched on again.'
            Write-Host ''
            Write-Host 'This is the decision of the owner of the PC. It lowers a protection of Windows.'
        } else {
            Write-Host 'An application control rule of the organisation that manages this PC stops the program.'
            Write-Host 'Only the person who manages this PC can allow it.'
        }
        Write-Host 'If you are not sure, call the person who sent you the link.'
        Write-Host 'No icon was made. Nothing outside the QargoAutofill folder was changed.'
        throw 'QA-BLOCKED'
    }

    function Test-LinkTarget {
        # Does the shortcut point at a file that is there? Read back two ways: through WScript.Shell, and through
        # Explorer's own link object, which is the one that knows every letter.
        param($Shell, [string]$Lnk)
        $targets = @()
        try { $targets += [string]$Shell.CreateShortcut($Lnk).TargetPath } catch { }
        try {
            $item = (New-Object -ComObject Shell.Application).NameSpace((Split-Path -Parent $Lnk)).ParseName((Split-Path -Leaf $Lnk))
            $targets += [string]$item.GetLink.Path
        } catch { }
        foreach ($t in $targets) {
            try { if ($t -and (Test-Path -LiteralPath $t -PathType Leaf)) { return $true } } catch { }
        }
        return $false
    }

    function Test-Blocked {
        # error 4551 = "An Application Control policy has blocked this file" (Python says WinError, uv says os error)
        param([string]$Text)
        return ($Text -match '(WinError|os error) 4551|Application Control policy')
    }

    # ---- 0. checks
    if ($DistUrl -notmatch '://') { throw 'This copy of the installer has no download address (it was not made by make_release.sh).' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows is needed.' }
    if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or 11 is needed.' }
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'bin') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'data\logs') | Out-Null
    try { Start-Transcript -Path (Join-Path $Root 'install.log') -Append | Out-Null } catch { }
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($Root).Substring(0, 1)) -ErrorAction SilentlyContinue
    if ($drive -and $drive.Free -lt 1500MB) { throw 'There is not enough free disk space (1.5 GB is needed).' }
    $sac = Get-SacState
    Write-Host "install-windows.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion), Smart App Control state $sac, from $DistUrl"
    if ($sac -eq 1) {
        Write-Host 'Note: Smart App Control is switched on on this PC. The installation is tried anyway;' -ForegroundColor Yellow
        Write-Host 'if Windows blocks the program you will get an explanation.' -ForegroundColor Yellow
    }

    # One installation at a time. The line pasted a second time while the first window is still downloading would
    # otherwise stop that window's uv and python below. The mark is this window's process id and start time.
    $LockFile = Join-Path $Root 'install.pid'
    $mine = "$PID $((Get-Process -Id $PID).StartTime.Ticks)"
    $busy = $false
    try {
        $theirs = [string](Get-Content -LiteralPath $LockFile -ErrorAction Stop | Select-Object -First 1)
        if ($theirs -and $theirs -ne $mine) {
            $other = Get-Process -Id ([int](($theirs -split ' ')[0])) -ErrorAction SilentlyContinue
            if ($other -and ("$($other.Id) $($other.StartTime.Ticks)" -eq $theirs)) { $busy = $true }
        }
    } catch { }
    if ($busy) { throw 'The installation is already running in another window. Wait until that window is finished.' }
    try {
        Set-Content -LiteralPath $LockFile -Value $mine -Encoding ASCII
        $global:QaLockFile = $LockFile              # removed at the very end, before "Press Enter"
    } catch { }

    # stop a running copy: only programs that run from inside our own folder (python, Playwright's driver and browser)
    $prefix = $Root.TrimEnd('\') + '\'
    $ours = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($ours.Count -gt 0) {
        $ours | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # ---- 1. uv (private copy, pinned version and checksum)
    $Uv = Join-Path $Root 'bin\uv.exe'
    $have = ''
    if (Test-Path -LiteralPath $Uv) { $have = (Invoke-Native $Uv @('--version') -Quiet).Text }
    if ($have -notlike "uv $UvVersion*") {
        Say "Step 1 of 4: downloading the installer tool (uv $UvVersion)"
        $zip = Join-Path $Root 'uv-download.zip'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/astral-sh/uv/releases/download/$UvVersion/$UvZip" -OutFile $zip
        } catch {
            throw "The download did not work. Is this PC connected to the internet? ($($_.Exception.Message))"
        }
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $UvSha256) { throw 'A downloaded file is damaged (uv: wrong checksum). Try again later.' }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $Root 'bin') -Force
        Remove-Item -LiteralPath $zip -Force
    } else {
        Say 'Step 1 of 4: the installer tool is already here'
    }
    $r = Invoke-Native $Uv @('--version')
    if (Test-Blocked $r.Text) { Stop-Blocked }
    if ($r.Code -ne 0) { throw 'The installer tool (uv) does not start on this PC.' }

    # ---- 2. Python (uv-managed, private to this program)
    $env:UV_PYTHON_INSTALL_DIR      = Join-Path $Root 'python'
    $env:UV_CACHE_DIR               = Join-Path $Root 'uv-cache'
    $env:UV_MANAGED_PYTHON          = '1'
    $env:UV_PYTHON_INSTALL_BIN      = '0'
    $env:UV_PYTHON_INSTALL_REGISTRY = '0'
    $env:UV_NO_CONFIG               = '1'
    $env:UV_SYSTEM_CERTS            = '1'
    $env:UV_NO_PROGRESS             = '1'
    $env:PYTHONUTF8                 = '1'
    foreach ($name in @('VIRTUAL_ENV', 'PYTHONHOME', 'PYTHONPATH', 'UV_PROJECT_ENVIRONMENT')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    Say 'Step 2 of 4: installing Python 3.13 (only for this program)'
    $r = Invoke-Native $Uv @('python', 'install', $PyRequest, '--no-bin', '--no-registry')
    if (Test-Blocked $r.Text) { Stop-Blocked }
    if ($r.Code -ne 0) { throw 'Python could not be installed. Is this PC connected to the internet?' }
    $r = Invoke-Native $Uv @('python', 'find', $PyRequest, '--no-project') -Quiet
    if (Test-Blocked $r.Text) { Stop-Blocked }
    $Py = ''
    foreach ($line in ($r.Text -split "`n")) {      # the line that is a file; uv may print a warning before it
        $t = $line.Trim()
        try { if ($t -and (Test-Path -LiteralPath $t -PathType Leaf)) { $Py = $t } } catch { }
    }
    if ($r.Code -ne 0 -or -not $Py) { throw 'Python was not found after installing it.' }
    $PyW = Join-Path (Split-Path -Parent $Py) 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $PyW)) { throw "pythonw.exe is missing next to $Py" }
    Write-Host "    python: $Py"
    # Does Windows let this Python run at all? (Smart App Control blocks programs it does not know.)
    $r = Invoke-Native $Py @('-c', 'import sys; print(sys.version)')
    if ($r.Code -ne 0) {
        if ((Test-Blocked $r.Text) -or ((Get-SacState) -eq 1)) { Stop-Blocked }
        throw 'The installed Python does not start on this PC.'
    }

    # ---- 3. the program: release zip, virtualenv from uv.lock, browser, self-test (all done by the launcher itself)
    Say "Step 3 of 4: installing $AppName (the first time this downloads about 300 MB and takes a few minutes)"
    $Launcher = Join-Path $Root 'qargo_launcher.py'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$DistUrl/qargo_launcher.py" -OutFile "$Launcher.new"
    } catch {
        throw "The program could not be downloaded. Is this PC connected to the internet? ($($_.Exception.Message))"
    }
    Move-Item -LiteralPath "$Launcher.new" -Destination $Launcher -Force
    $env:QARGO_HOME = $Root
    $env:QARGO_VERBOSE = '1'
    $LauncherArgs = @($Launcher, 'install', '--dist', $DistUrl)
    if ($Site) { $LauncherArgs += @('--site', $Site) }
    $r = Invoke-Native $Py $LauncherArgs
    $env:QARGO_VERBOSE = $null
    if ($r.Code -eq 45 -or (Test-Blocked $r.Text)) { Stop-Blocked }
    if ($r.Code -eq 3) { throw 'Qargo Autofill is still open. Close its window and run the same line again.' }
    if ($r.Code -eq 4) { throw 'This line has no site code. Open the link you were sent (it ends in #s=...) and copy the line from that page.' }

    # Start the installed Python for real and load the two parts Windows is most likely to stop (compiled, unsigned).
    $VenvPy = ''
    $s = Invoke-Native $Py @($Launcher, 'status') -Quiet
    try { $VenvPy = [string]((ConvertFrom-Json $s.Text).python) } catch { $VenvPy = '' }
    if (-not $VenvPy) {                              # nothing was activated: look at what was built so far
        $found = Get-ChildItem -Path (Join-Path $Root 'envs\*\Scripts\python.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $VenvPy = $found.FullName }
    }
    if ($VenvPy -and (Test-Path -LiteralPath $VenvPy)) {
        $c = Invoke-Native $VenvPy @('-c', 'import greenlet, playwright.sync_api; print(''imports ok'')')
        if ($c.Code -ne 0) {
            if ((Test-Blocked $c.Text) -or ((Get-SacState) -eq 1)) { Stop-Blocked }
            throw 'The program was installed but its parts do not load. The details are in install.log.'
        }
    }
    if ($r.Code -ne 0) { throw 'The program could not be installed. The details are in install.log.' }

    # ---- 4. shortcuts: pythonw.exe (no console window) runs the launcher; each double-click runs it again
    Say "Step 4 of 4: making the $AppName icon"
    $Icon = Join-Path $Root 'assets\icon.ico'
    $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
    if ($env:QARGO_SHORTCUT_DIRS) { $dirs = $env:QARGO_SHORTCUT_DIRS -split ';' }
    $shell = New-Object -ComObject WScript.Shell
    $made = @()
    foreach ($dir in $dirs) {
        if (-not $dir) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $lnk = Join-Path $dir "$AppName.lnk"
            $ok = $false
            try {
                $s = $shell.CreateShortcut($lnk)
                $s.TargetPath = $PyW
                $s.Arguments = '"' + $Launcher + '" launch'
                $s.WorkingDirectory = $Root
                if (Test-Path -LiteralPath $Icon) { $s.IconLocation = $Icon + ',0' }
                $s.Description = $AppName
                $s.WindowStyle = 1
                $s.Save()
                $ok = Test-LinkTarget $shell $lnk
            } catch {
                Write-Host "    (first try for ${dir}: $($_.Exception.Message))"
            }
            if (-not $ok) {
                # WScript.Shell keeps these texts in the code page of the PC: a letter outside it in the user's folder
                # name (C:\Users\<name>\...) is stored as "?" and the icon starts nothing. Explorer's own link object
                # stores every letter; it needs a link file to begin with.
                if (-not (Test-Path -LiteralPath $lnk)) {
                    $s = $shell.CreateShortcut($lnk)
                    $s.TargetPath = Join-Path $env:SystemRoot 'explorer.exe'
                    $s.Save()
                }
                $link = (New-Object -ComObject Shell.Application).NameSpace($dir).ParseName("$AppName.lnk").GetLink
                $link.Path = $PyW
                $link.Arguments = '"' + $Launcher + '" launch'
                $link.WorkingDirectory = $Root
                $link.Description = $AppName
                if (Test-Path -LiteralPath $Icon) { $link.SetIconLocation($Icon, 0) }
                $link.Save()
                if (-not (Test-LinkTarget $shell $lnk)) {
                    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
                    throw 'the icon would not start the program (Windows could not store the name of the folder)'
                }
            }
            $made += $lnk
            Write-Host "    icon: $lnk"
        } catch {
            Write-Host "    no icon in ${dir}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($made.Count -eq 0) { throw 'The icon could not be made.' }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  Qargo Autofill is installed.' -ForegroundColor Green
    $onDesktop = $false
    if ($dirs[0]) { $onDesktop = ($made -contains (Join-Path $dirs[0] "$AppName.lnk")) }
    if ($onDesktop) {
        Write-Host '  Start it with the blue "Qargo Autofill" icon on the Desktop.' -ForegroundColor Green
    } else {
        Write-Host '  There is no icon on the Desktop. Start it from the Start menu:' -ForegroundColor Green
        Write-Host '  press the Windows key, type Qargo, press Enter.' -ForegroundColor Green
    }
    Write-Host '============================================================' -ForegroundColor Green
    if ((Get-SacState) -eq 2) {
        Write-Host 'Note for the owner: Smart App Control is in its trial ("evaluation") mode on this PC.'
        Write-Host 'Windows may switch it on by itself later. If the program then stops starting, run this line again: it will explain.'
    }
    if (-not $env:QARGO_NO_OPEN) {
        # it IS installed: a start that fails here must not end in "could NOT be installed"
        try { Start-Process -FilePath $made[0] } catch { Write-Host 'The program did not start by itself. Start it with its icon.' -ForegroundColor Yellow }
    }
}

$QaExit = 0
try {
    Install-QargoAutofill
} catch {
    $QaExit = 1
    if ("$($_.Exception.Message)" -eq 'QA-BLOCKED') {
        $QaExit = 2
    } else {
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Red
        Write-Host '  Qargo Autofill could NOT be installed.' -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '============================================================' -ForegroundColor Red
        Write-Host 'Nothing outside the QargoAutofill folder was changed.'
        Write-Host 'Please call the person who sent you the link.'
    }
} finally {
    if ($global:QaLockFile) { Remove-Item -LiteralPath $global:QaLockFile -Force -ErrorAction SilentlyContinue }
    $global:QaLockFile = $null
    try { Stop-Transcript | Out-Null } catch { }
}
if ($env:QARGO_NONINTERACTIVE) { exit $QaExit }
Read-Host 'Press Enter to close this window' | Out-Null
