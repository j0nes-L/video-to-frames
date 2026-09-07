#requires -version 5.1
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppTitle    = 'Convert into frames - Setup'
$MenuText    = 'Convert into frames'
$KeyName     = 'ConvertIntoFrames'
$Root        = $PSScriptRoot
$ScriptFile  = Join-Path $Root 'ConvertToFrames.ps1'
$LauncherExe = Join-Path $Root 'ConvertToFramesLauncher.exe'
$IconFile    = Join-Path $Root 'ConvertToFrames.ico'
$ConfigFile  = Join-Path $Root 'config.json'

$Extensions = @(
    '.mp4', '.m4v', '.mov', '.mkv', '.avi', '.wmv', '.webm', '.flv',
    '.mpg', '.mpeg', '.mts', '.m2ts', '.ts', '.3gp', '.ogv', '.insv'
)

function Show-Info([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($Text, $AppTitle, 'OK', $Icon)
}

function Resolve-Tool([string]$Name) {
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
            if ($cfg.ffmpegDir) {
                $p = Join-Path $cfg.ffmpegDir "$Name.exe"
                if (Test-Path -LiteralPath $p) { return $p }
            }
        } catch { }
    }

    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $Root "$Name.exe")
        (Join-Path $Root "bin\$Name.exe")
        (Join-Path $Root "ffmpeg\bin\$Name.exe")
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\$Name.exe"
        "$env:ProgramFiles\ffmpeg\bin\$Name.exe"
        "${env:ProgramFiles(x86)}\ffmpeg\bin\$Name.exe"
        "C:\ffmpeg\bin\$Name.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }

    $wingetPkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetPkgs) {
        $hit = Get-ChildItem -LiteralPath $wingetPkgs -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function New-AppIcon {
    if (Test-Path -LiteralPath $IconFile) { return $IconFile }
    try {
        $size = 64
        $bmp  = New-Object System.Drawing.Bitmap($size, $size)
        $g    = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)

        $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 38, 42, 52))
        $g.FillRectangle($body, 4, 10, 56, 44)

        $hole = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 236, 239, 245))
        for ($x = 8; $x -lt 58; $x += 10) {
            $g.FillRectangle($hole, $x, 13, 6, 5)
            $g.FillRectangle($hole, $x, 46, 6, 5)
        }

        $accent = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 149, 41))
        $pts = @(
            (New-Object System.Drawing.Point(26, 23)),
            (New-Object System.Drawing.Point(45, 32)),
            (New-Object System.Drawing.Point(26, 41))
        )
        $g.FillPolygon($accent, $pts)
        $g.Dispose()

        $maskStride = [int](([math]::Floor(($size + 31) / 32)) * 4)
        $xorSize    = $size * $size * 4
        $maskSize   = $size * $maskStride
        $imageSize  = 40 + $xorSize + $maskSize

        $fs = [System.IO.File]::Create($IconFile)
        $bw = New-Object System.IO.BinaryWriter($fs)

        $bw.Write([uint16]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]1)
        $bw.Write([byte]$size)
        $bw.Write([byte]$size)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$imageSize)
        $bw.Write([uint32]22)

        $bw.Write([uint32]40)
        $bw.Write([int32]$size)
        $bw.Write([int32]($size * 2))
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]0)
        $bw.Write([uint32]($xorSize + $maskSize))
        $bw.Write([int32]0)
        $bw.Write([int32]0)
        $bw.Write([uint32]0)
        $bw.Write([uint32]0)

        for ($y = $size - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $size; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $bw.Write([byte]$c.B)
                $bw.Write([byte]$c.G)
                $bw.Write([byte]$c.R)
                $bw.Write([byte]$c.A)
            }
        }
        $bw.Write((New-Object byte[] $maskSize))

        $bw.Flush()
        $bw.Dispose()
        $fs.Dispose()
        $bmp.Dispose()
        return $IconFile
    } catch {
        return $null
    }
}

function New-Launcher {
    $csharp = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

public static class FramesLauncher
{
    [STAThread]
    public static void Main(string[] args)
    {
        string dir    = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "ConvertToFrames.ps1");

        StringBuilder sb = new StringBuilder();
        sb.Append("-NoProfile -NoLogo -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"");
        sb.Append(script).Append("\"");
        if (args.Length > 0)
        {
            sb.Append(" -Path \"").Append(args[0].TrimEnd('\\')).Append("\"");
        }

        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", sb.ToString());
        psi.UseShellExecute  = false;
        psi.CreateNoWindow   = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
'@
    try {
        if (Test-Path -LiteralPath $LauncherExe) { Remove-Item -LiteralPath $LauncherExe -Force }
        Add-Type -TypeDefinition $csharp -OutputAssembly $LauncherExe -OutputType WindowsApplication `
                 -ReferencedAssemblies 'System.dll' -ErrorAction Stop
        return $LauncherExe
    } catch {
        return $null
    }
}

function Get-InstalledExtensions {
    $found = @()
    foreach ($ext in $Extensions) {
        $key = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$KeyName"
        if (Test-Path -LiteralPath $key) { $found += $ext }
    }
    return $found
}

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = $AppTitle
$form.ClientSize      = New-Object System.Drawing.Size(470, 470)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$lblIntro = New-Object System.Windows.Forms.Label
$lblIntro.Text     = 'Adds "Convert into frames" to the right-click menu of video files. Only the current user account is changed, no admin rights needed.'
$lblIntro.Location = New-Object System.Drawing.Point(14, 12)
$lblIntro.Size     = New-Object System.Drawing.Size(442, 42)

$grpFF = New-Object System.Windows.Forms.GroupBox
$grpFF.Text     = ' ffmpeg '
$grpFF.Location = New-Object System.Drawing.Point(14, 60)
$grpFF.Size     = New-Object System.Drawing.Size(442, 82)

$lblFF = New-Object System.Windows.Forms.Label
$lblFF.Location  = New-Object System.Drawing.Point(14, 24)
$lblFF.Size      = New-Object System.Drawing.Size(414, 30)
$lblFF.AutoSize  = $false

$btnFF = New-Object System.Windows.Forms.Button
$btnFF.Text     = 'Install ffmpeg'
$btnFF.Location = New-Object System.Drawing.Point(14, 50)
$btnFF.Size     = New-Object System.Drawing.Size(130, 26)

$btnFFPick = New-Object System.Windows.Forms.Button
$btnFFPick.Text     = 'Select manually'
$btnFFPick.Location = New-Object System.Drawing.Point(152, 50)
$btnFFPick.Size     = New-Object System.Drawing.Size(130, 26)

$grpFF.Controls.AddRange(@($lblFF, $btnFF, $btnFFPick))

$grpExt = New-Object System.Windows.Forms.GroupBox
$grpExt.Text     = ' File types '
$grpExt.Location = New-Object System.Drawing.Point(14, 150)
$grpExt.Size     = New-Object System.Drawing.Size(442, 218)

$clb = New-Object System.Windows.Forms.CheckedListBox
$clb.Location      = New-Object System.Drawing.Point(14, 22)
$clb.Size          = New-Object System.Drawing.Size(414, 154)
$clb.CheckOnClick  = $true
$clb.MultiColumn   = $true
$clb.ColumnWidth   = 100
$clb.IntegralHeight = $false

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text     = 'Select all'
$btnAll.Location = New-Object System.Drawing.Point(14, 182)
$btnAll.Size     = New-Object System.Drawing.Size(100, 26)

$btnNone = New-Object System.Windows.Forms.Button
$btnNone.Text     = 'Select none'
$btnNone.Location = New-Object System.Drawing.Point(122, 182)
$btnNone.Size     = New-Object System.Drawing.Size(100, 26)

$grpExt.Controls.AddRange(@($clb, $btnAll, $btnNone))

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(14, 376)
$lblStatus.Size     = New-Object System.Drawing.Size(442, 34)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text     = 'Add to right-click menu'
$btnInstall.Location = New-Object System.Drawing.Point(14, 424)
$btnInstall.Size     = New-Object System.Drawing.Size(180, 32)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text     = 'Remove'
$btnRemove.Location = New-Object System.Drawing.Point(202, 424)
$btnRemove.Size     = New-Object System.Drawing.Size(120, 32)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(340, 424)
$btnClose.Size     = New-Object System.Drawing.Size(116, 32)

$form.Controls.AddRange(@($lblIntro, $grpFF, $grpExt, $lblStatus, $btnInstall, $btnRemove, $btnClose))

foreach ($ext in $Extensions) { [void]$clb.Items.Add($ext, $true) }

function Update-FFmpegState {
    $ff = Resolve-Tool 'ffmpeg'
    if ($ff) {
        $lblFF.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
        $lblFF.Text      = "Found: $ff"
        $btnFF.Text      = 'Reinstall ffmpeg'
    } else {
        $lblFF.ForeColor = [System.Drawing.Color]::Firebrick
        $lblFF.Text      = 'Not found. The tool needs ffmpeg to extract frames.'
        $btnFF.Text      = 'Install ffmpeg'
    }
    return $ff
}

function Update-InstallState {
    $installed = Get-InstalledExtensions
    if ($installed.Count -gt 0) {
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
        $lblStatus.Text = ("Currently active for {0} file types: {1}" -f $installed.Count, ($installed -join ' '))
        $btnRemove.Enabled = $true
        for ($i = 0; $i -lt $clb.Items.Count; $i++) {
            $clb.SetItemChecked($i, ($installed -contains $clb.Items[$i]))
        }
    } else {
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = 'Not installed yet. Pick the file types and click "Add to right-click menu".'
        $btnRemove.Enabled = $false
    }
}

$btnAll.Add_Click({  for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })
$btnNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })

$btnFF.Add_Click({
    $form.Enabled = $false
    $lblFF.Text = 'Installing ffmpeg via winget, please wait ...'
    $form.Refresh()
    try {
        $wingetArgs = 'install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements'
        Start-Process -FilePath 'winget.exe' -ArgumentList $wingetArgs -Wait
    } catch {
        Show-Info "winget could not be started:`n$($_.Exception.Message)" 'Error'
    }
    $form.Enabled = $true
    [void](Update-FFmpegState)
})

$btnFFPick.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = 'Select ffmpeg.exe'
    $dlg.Filter = 'ffmpeg.exe|ffmpeg.exe|Programs (*.exe)|*.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            @{ ffmpegDir = (Split-Path -Parent $dlg.FileName) } | ConvertTo-Json |
                Set-Content -LiteralPath $ConfigFile -Encoding UTF8
        } catch {
            Show-Info "The selection could not be saved:`n$($_.Exception.Message)" 'Error'
        }
        [void](Update-FFmpegState)
    }
})

$btnInstall.Add_Click({
    if (-not (Test-Path -LiteralPath $ScriptFile)) {
        Show-Info "ConvertToFrames.ps1 is missing in`n$Root" 'Error'
        return
    }

    $selected = @($clb.CheckedItems)
    if ($selected.Count -eq 0) {
        Show-Info 'Please select at least one file type.' 'Warning'
        return
    }

    $icon    = New-AppIcon
    $exe     = New-Launcher
    $flicker = $false

    if ($exe) {
        $command = '"{0}" "%1"' -f $exe
    } else {
        $flicker = $true
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $command = '"' + $ps + '" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' +
                   $ScriptFile + '" -Path "%1"'
    }

    try {
        foreach ($ext in $Extensions) {
            $base = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$KeyName"
            if ($selected -contains $ext) {
                New-Item -Path "$base\command" -Force | Out-Null
                Set-ItemProperty -LiteralPath $base -Name '(default)' -Value $MenuText
                Set-ItemProperty -LiteralPath $base -Name 'MUIVerb'   -Value $MenuText
                if ($icon) { Set-ItemProperty -LiteralPath $base -Name 'Icon' -Value "$icon,0" }
                Set-ItemProperty -LiteralPath "$base\command" -Name '(default)' -Value $command
            }
            elseif (Test-Path -LiteralPath $base) {
                Remove-Item -LiteralPath $base -Recurse -Force
            }
        }
    } catch {
        Show-Info "The registry entry could not be written:`n$($_.Exception.Message)" 'Error'
        return
    }

    Update-InstallState

    $msg = "Done. Right-click any video and choose `"$MenuText`"." + [Environment]::NewLine + [Environment]::NewLine +
           'On Windows 11 the entry sits in the classic menu, so open "Show more options" or press Shift while right-clicking.'
    if ($flicker) {
        $msg += [Environment]::NewLine + [Environment]::NewLine +
                'Note: the helper program could not be compiled, so a console window will flash briefly when the dialog opens.'
    }
    Show-Info $msg
})

$btnRemove.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        'Remove the right-click entry for all file types?', $AppTitle, 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    try {
        foreach ($ext in $Extensions) {
            $base = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$KeyName"
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        }
    } catch {
        Show-Info "The entry could not be removed:`n$($_.Exception.Message)" 'Error'
        return
    }

    for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) }
    Update-InstallState
    Show-Info 'The right-click entry has been removed.'
})

$btnClose.Add_Click({ $form.Close() })

$icon = New-AppIcon
if ($icon) {
    try { $form.Icon = New-Object System.Drawing.Icon($icon) } catch { }
}

[void](Update-FFmpegState)
Update-InstallState
[void]$form.ShowDialog()
$form.Dispose()
