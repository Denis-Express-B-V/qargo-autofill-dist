# Qargo Autofill - uninstall for Windows. Removes the program and its icons; keeps the data folder (documents, login,
# done list, logs) unless QARGO_REMOVE_DATA=1.
#
#   keep the data:      powershell -NoProfile -ExecutionPolicy Bypass -Command "try{irm https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main/uninstall-windows.ps1|iex}catch{Write-Host $_;Read-Host 'Press Enter to close'}"
#   remove everything:  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:QARGO_REMOVE_DATA=1;try{irm https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main/uninstall-windows.ps1|iex}catch{Write-Host $_;Read-Host 'Press Enter to close'}"
#
# Written for Windows PowerShell 5.1 and for "iex": ASCII only. Test overrides: QARGO_HOME, QARGO_SHORTCUT_DIRS
# (';' separated), QARGO_NONINTERACTIVE=1 (no "Press Enter").

# ---- Preflight (cmdlets only, as in install-windows.ps1): say so plainly when PowerShell is restricted on this PC
$ErrorActionPreference = 'Stop'
$QaLanguageMode = $ExecutionContext.SessionState.LanguageMode
if ("$QaLanguageMode" -ne 'FullLanguage') {
    Write-Host "Windows only allows restricted commands here (PowerShell language mode: $QaLanguageMode)."
    Write-Host 'Nothing was removed. Please call the person who sent you the link.'
    if ($env:QARGO_NONINTERACTIVE) { exit 3 }
    Read-Host 'Press Enter to close this window' | Out-Null
    return
}

function Uninstall-QargoAutofill {
    $AppName = 'Qargo Autofill'
    $Root = Join-Path $env:LOCALAPPDATA 'QargoAutofill'
    if ($env:QARGO_HOME) { $Root = $env:QARGO_HOME }
    $prefix = $Root.TrimEnd('\') + '\'

    # stop the program: only what runs from inside our own folder (python, Playwright's driver and browser, uv)
    $ours = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($ours.Count -gt 0) {
        $ours | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # the icons: only shortcuts that start something inside our folder
    $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
    if ($env:QARGO_SHORTCUT_DIRS) { $dirs = $env:QARGO_SHORTCUT_DIRS -split ';' }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in $dirs) {
        if (-not $dir) { continue }
        $lnk = Join-Path $dir "$AppName.lnk"
        if (-not (Test-Path -LiteralPath $lnk)) { continue }
        $target = ''
        try { $target = [string]$shell.CreateShortcut($lnk).TargetPath } catch { $target = '' }
        if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            # WScript.Shell gives "?" for a letter outside the code page of the PC; Explorer's own link object does not
            try {
                $target = [string](New-Object -ComObject Shell.Application).NameSpace($dir).ParseName("$AppName.lnk").GetLink.Path
            } catch { $target = '' }
        }
        if ($target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $lnk -Force }
    }

    if (Test-Path -LiteralPath $Root) {
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force)) {
            if ($item.Name -eq 'data' -and -not $env:QARGO_REMOVE_DATA) { continue }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
        }
        if (@(Get-ChildItem -LiteralPath $Root -Force).Count -eq 0) { Remove-Item -LiteralPath $Root -Force }
    }
    Write-Host ''
    Write-Host 'Qargo Autofill was removed.'
    $data = Join-Path $Root 'data'
    if (Test-Path -LiteralPath $data) {
        Write-Host 'Your documents, the Qargo login and the logs were kept in:'
        Write-Host "  $data"
    }
}

$QaExit = 0
try {
    Uninstall-QargoAutofill
} catch {
    $QaExit = 1
    Write-Host ''
    Write-Host "Qargo Autofill could not be removed completely: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Close the program and run the same line again.'
}
if ($env:QARGO_NONINTERACTIVE) { exit $QaExit }
Read-Host 'Press Enter to close this window' | Out-Null
