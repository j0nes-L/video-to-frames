#requires -version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Inv        = [System.Globalization.CultureInfo]::InvariantCulture
$AppTitle   = 'Convert into frames'
$ConfigFile = Join-Path $PSScriptRoot 'config.json'

function Show-Info([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($Text, $AppTitle, 'OK', $Icon)
}

function Q([string]$Value) {
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Capture([string]$Exe, [string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $p   = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
}

function Get-Config {
    if (Test-Path -LiteralPath $ConfigFile) {
        try { return (Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

function Save-Config([hashtable]$Data) {
    try { ($Data | ConvertTo-Json) | Set-Content -LiteralPath $ConfigFile -Encoding UTF8 } catch { }
}

function Resolve-Tool([string]$Name) {
    $cfg = Get-Config
    if ($cfg -and $cfg.ffmpegDir) {
        $p = Join-Path $cfg.ffmpegDir "$Name.exe"
        if (Test-Path -LiteralPath $p) { return $p }
    }

    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $PSScriptRoot "$Name.exe")
        (Join-Path $PSScriptRoot "bin\$Name.exe")
        (Join-Path $PSScriptRoot "ffmpeg\bin\$Name.exe")
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

function Confirm-FFmpeg {
    $ffmpeg = Resolve-Tool 'ffmpeg'
    if ($ffmpeg) { return $ffmpeg }

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "ffmpeg was not found on this system." + [Environment]::NewLine + [Environment]::NewLine +
        "Yes      -  download and install it now (winget, Gyan.FFmpeg)" + [Environment]::NewLine +
        "No       -  select an existing ffmpeg.exe yourself" + [Environment]::NewLine +
        "Cancel   -  quit",
        $AppTitle, 'YesNoCancel', 'Warning')

    if ($answer -eq 'Yes') {
        $wingetArgs = 'install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements'
        try {
            Start-Process -FilePath 'winget.exe' -ArgumentList $wingetArgs -Wait
        } catch {
            Show-Info "winget could not be started:`n$($_.Exception.Message)" 'Error'
            return $null
        }
        $ffmpeg = Resolve-Tool 'ffmpeg'
        if (-not $ffmpeg) { Show-Info 'ffmpeg was still not found after the installation.' 'Error' }
        return $ffmpeg
    }

    if ($answer -eq 'No') {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = 'Select ffmpeg.exe'
        $dlg.Filter = 'ffmpeg.exe|ffmpeg.exe|Programs (*.exe)|*.exe'
        if ($dlg.ShowDialog() -eq 'OK') {
            Save-Config @{ ffmpegDir = (Split-Path -Parent $dlg.FileName) }
            return $dlg.FileName
        }
    }
    return $null
}

function ConvertTo-Seconds([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parts = ($Text.Trim() -replace ',', '.').Split(':')
    if ($parts.Count -gt 3) { return $null }
    [double]$total = 0
    foreach ($p in $parts) {
        $v = 0.0
        if (-not [double]::TryParse($p, [System.Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { return $null }
        if ($v -lt 0) { return $null }
        $total = $total * 60 + $v
    }
    return $total
}

function Format-Timecode([double]$Seconds) {
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    return ('{0:00}:{1:00}:{2:00}.{3:000}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
}

function Get-VideoInfo([string]$File, [string]$FFmpegPath) {
    $duration = 0.0
    $fps      = 0.0
    $width    = 0
    $height   = 0

    $ffprobe = Resolve-Tool 'ffprobe'
    if (-not $ffprobe) {
        $sibling = Join-Path (Split-Path -Parent $FFmpegPath) 'ffprobe.exe'
        if (Test-Path -LiteralPath $sibling) { $ffprobe = $sibling }
    }

    if ($ffprobe) {
        $a = '-v error -select_streams v:0 -show_entries stream=r_frame_rate,width,height ' +
             '-show_entries format=duration -of default=noprint_wrappers=1 ' + (Q $File)
        $r = Invoke-Capture $ffprobe $a
        foreach ($line in ($r.StdOut -split "`r?`n")) {
            if ($line -match '^duration=([\d\.]+)') {
                [void][double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float, $Inv, [ref]$duration)
            }
            elseif ($line -match '^width=(\d+)')  { $width  = [int]$Matches[1] }
            elseif ($line -match '^height=(\d+)') { $height = [int]$Matches[1] }
            elseif ($line -match '^r_frame_rate=(\d+)/(\d+)') {
                $den = [double]$Matches[2]
                if ($den -gt 0) { $fps = [double]$Matches[1] / $den }
            }
        }
    }

    if ($duration -le 0) {
        $r = Invoke-Capture $FFmpegPath ('-hide_banner -i ' + (Q $File))
        if ($r.StdErr -match 'Duration:\s*(\d+):(\d+):(\d+\.\d+)') {
            $duration = [double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + [double]::Parse($Matches[3], $Inv)
        }
        if ($fps -le 0 -and $r.StdErr -match '([\d\.]+)\s*fps') {
            [void][double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float, $Inv, [ref]$fps)
        }
        if ($width -le 0 -and $r.StdErr -match 'Video:.*?(\d{2,5})x(\d{2,5})') {
            $width  = [int]$Matches[1]
            $height = [int]$Matches[2]
        }
    }

    [pscustomobject]@{ Duration = $duration; Fps = $fps; Width = $width; Height = $height }
}

$ffmpegPath = Confirm-FFmpeg
if (-not $ffmpegPath) { return }

if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = 'Select a video'
    $dlg.Filter = 'Video files|*.mp4;*.mov;*.mkv;*.avi;*.wmv;*.m4v;*.mpg;*.mpeg;*.webm;*.flv;*.mts;*.m2ts;*.ts;*.3gp;*.insv|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $Path = $dlg.FileName
}

$videoPath = (Resolve-Path -LiteralPath $Path).Path
$videoDir  = Split-Path -Parent $videoPath
$videoName = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)

$info = Get-VideoInfo $videoPath $ffmpegPath
if ($info.Duration -le 0) {
    Show-Info "The duration of this file could not be determined.`n`n$videoPath" 'Error'
    return
}

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = $AppTitle
$form.ClientSize      = New-Object System.Drawing.Size(580, 534)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.MinimizeBox     = $false
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$iconFile = Join-Path $PSScriptRoot 'ConvertToFrames.ico'
if (Test-Path -LiteralPath $iconFile) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconFile) } catch { }
}

function New-Label($Text, $X, $Y, $W = 70) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size     = New-Object System.Drawing.Size($W, 18)
    return $l
}

$lblVideo = New-Label 'Video' 14 15
$txtVideo = New-Object System.Windows.Forms.TextBox
$txtVideo.Location = New-Object System.Drawing.Point(88, 12)
$txtVideo.Size     = New-Object System.Drawing.Size(478, 22)
$txtVideo.ReadOnly = $true
$txtVideo.Text     = $videoPath

$lblMeta = New-Label ('Duration {0}      Resolution {1} x {2}      Source {3} fps' -f `
                      (Format-Timecode $info.Duration), $info.Width, $info.Height,
                      ([math]::Round($info.Fps, 3)).ToString($Inv)) 88 40 478
$lblMeta.ForeColor = [System.Drawing.Color]::DimGray

$grpTime = New-Object System.Windows.Forms.GroupBox
$grpTime.Text     = ' Time range '
$grpTime.Location = New-Object System.Drawing.Point(14, 66)
$grpTime.Size     = New-Object System.Drawing.Size(552, 62)

$txtStart = New-Object System.Windows.Forms.TextBox
$txtStart.Location = New-Object System.Drawing.Point(62, 24)
$txtStart.Size     = New-Object System.Drawing.Size(110, 22)
$txtStart.Text     = '00:00:00.000'

$txtEnd = New-Object System.Windows.Forms.TextBox
$txtEnd.Location = New-Object System.Drawing.Point(250, 24)
$txtEnd.Size     = New-Object System.Drawing.Size(110, 22)
$txtEnd.Text     = Format-Timecode $info.Duration

$btnFull = New-Object System.Windows.Forms.Button
$btnFull.Text     = 'Whole video'
$btnFull.Location = New-Object System.Drawing.Point(420, 22)
$btnFull.Size     = New-Object System.Drawing.Size(118, 26)

$grpTime.Controls.AddRange(@(
    (New-Label 'Start' 14 27 46), $txtStart,
    (New-Label 'End' 200 27 44), $txtEnd,
    $btnFull
))

$grpFps = New-Object System.Windows.Forms.GroupBox
$grpFps.Text     = ' Frames '
$grpFps.Location = New-Object System.Drawing.Point(14, 134)
$grpFps.Size     = New-Object System.Drawing.Size(552, 112)

$rbFps = New-Object System.Windows.Forms.RadioButton
$rbFps.Text     = 'Frames per second'
$rbFps.Location = New-Object System.Drawing.Point(14, 22)
$rbFps.Size     = New-Object System.Drawing.Size(160, 22)
$rbFps.Checked  = $true

$numFps = New-Object System.Windows.Forms.NumericUpDown
$numFps.Location      = New-Object System.Drawing.Point(180, 22)
$numFps.Size          = New-Object System.Drawing.Size(80, 22)
$numFps.DecimalPlaces = 2
$numFps.Increment     = 1
$numFps.Minimum       = 0.01
$numFps.Maximum       = 240
$numFps.Value         = 1

$rbAll = New-Object System.Windows.Forms.RadioButton
$rbAll.Text     = ('Every frame of the source ({0} fps)' -f ([math]::Round($info.Fps, 3)).ToString($Inv))
$rbAll.Location = New-Object System.Drawing.Point(14, 50)
$rbAll.Size     = New-Object System.Drawing.Size(320, 22)

$rbCount = New-Object System.Windows.Forms.RadioButton
$rbCount.Text     = 'Fixed number of frames'
$rbCount.Location = New-Object System.Drawing.Point(14, 78)
$rbCount.Size     = New-Object System.Drawing.Size(160, 22)

$numCount = New-Object System.Windows.Forms.NumericUpDown
$numCount.Location = New-Object System.Drawing.Point(180, 78)
$numCount.Size     = New-Object System.Drawing.Size(80, 22)
$numCount.Minimum  = 1
$numCount.Maximum  = 100000
$numCount.Value    = 150
$numCount.Enabled  = $false

$lblEstimate = New-Label '' 290 80 250
$lblEstimate.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
$lblEstimate.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$grpFps.Controls.AddRange(@($rbFps, $numFps, $rbAll, $rbCount, $numCount, $lblEstimate))

$grpOut = New-Object System.Windows.Forms.GroupBox
$grpOut.Text     = ' Output '
$grpOut.Location = New-Object System.Drawing.Point(14, 252)
$grpOut.Size     = New-Object System.Drawing.Size(552, 148)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(74, 22)
$txtOut.Size     = New-Object System.Drawing.Size(378, 22)
$txtOut.Text     = $videoDir

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text     = 'Browse'
$btnBrowse.Location = New-Object System.Drawing.Point(460, 20)
$btnBrowse.Size     = New-Object System.Drawing.Size(78, 26)

$chkSub = New-Object System.Windows.Forms.CheckBox
$chkSub.Text     = ('Create subfolder "{0}_frames"' -f $videoName)
$chkSub.Location = New-Object System.Drawing.Point(74, 48)
$chkSub.Size     = New-Object System.Drawing.Size(380, 22)

$cmbFormat = New-Object System.Windows.Forms.ComboBox
$cmbFormat.Location      = New-Object System.Drawing.Point(74, 76)
$cmbFormat.Size          = New-Object System.Drawing.Size(70, 22)
$cmbFormat.DropDownStyle = 'DropDownList'
[void]$cmbFormat.Items.AddRange(@('JPG', 'PNG'))
$cmbFormat.SelectedIndex = 0

$lblQ = New-Label 'Quality' 160 79 60
$numQ = New-Object System.Windows.Forms.NumericUpDown
$numQ.Location = New-Object System.Drawing.Point(224, 76)
$numQ.Size     = New-Object System.Drawing.Size(56, 22)
$numQ.Minimum  = 1
$numQ.Maximum  = 31
$numQ.Value    = 2

$lblQHint = New-Label '1 = best quality, 31 = smallest file' 288 79 250
$lblQHint.ForeColor = [System.Drawing.Color]::DimGray

$lblW = New-Label 'Width' 14 111 56
$numW = New-Object System.Windows.Forms.NumericUpDown
$numW.Location  = New-Object System.Drawing.Point(74, 108)
$numW.Size      = New-Object System.Drawing.Size(70, 22)
$numW.Minimum   = 0
$numW.Maximum   = 16384
$numW.Increment = 100
$numW.Value     = 0

$lblWHint = New-Label 'px, 0 = original' 150 111 110
$lblWHint.ForeColor = [System.Drawing.Color]::DimGray

$lblP = New-Label 'Prefix' 288 111 50
$txtPrefix = New-Object System.Windows.Forms.TextBox
$txtPrefix.Location = New-Object System.Drawing.Point(342, 108)
$txtPrefix.Size     = New-Object System.Drawing.Size(196, 22)
$txtPrefix.Text     = 'frame_'

$grpOut.Controls.AddRange(@(
    (New-Label 'Folder' 14 25 56), $txtOut, $btnBrowse, $chkSub,
    (New-Label 'Format' 14 79 56), $cmbFormat, $lblQ, $numQ, $lblQHint,
    $lblW, $numW, $lblWHint, $lblP, $txtPrefix
))

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(14, 410)
$bar.Size     = New-Object System.Drawing.Size(552, 16)

$lblStatus = New-Label 'Ready.' 14 432 552
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text     = 'Open folder'
$btnOpen.Location = New-Object System.Drawing.Point(14, 464)
$btnOpen.Size     = New-Object System.Drawing.Size(120, 30)
$btnOpen.Enabled  = $false

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text     = 'Start'
$btnStart.Location = New-Object System.Drawing.Point(326, 464)
$btnStart.Size     = New-Object System.Drawing.Size(116, 30)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(450, 464)
$btnClose.Size     = New-Object System.Drawing.Size(116, 30)

$form.Controls.AddRange(@(
    $lblVideo, $txtVideo, $lblMeta, $grpTime, $grpFps, $grpOut,
    $bar, $lblStatus, $btnOpen, $btnStart, $btnClose
))
$form.AcceptButton = $btnStart

$script:proc         = $null
$script:progressFile = $null
$script:running      = $false
$script:cancelled    = $false
$script:totalLength  = 0.0
$script:outFilter    = '*.jpg'
$script:lastOutDir   = $videoDir

function Get-Range {
    $s = ConvertTo-Seconds $txtStart.Text
    $e = ConvertTo-Seconds $txtEnd.Text
    if ($null -eq $s -or $null -eq $e) { return $null }
    if ($s -gt $info.Duration) { $s = $info.Duration }
    if ($e -gt $info.Duration) { $e = $info.Duration }
    if ($e -le $s) { return $null }
    [pscustomobject]@{ Start = $s; End = $e; Length = $e - $s }
}

function Get-EffectiveFps($Range) {
    if ($rbAll.Checked)   { return 0.0 }
    if ($rbCount.Checked) { return [double]$numCount.Value / $Range.Length }
    return [double]$numFps.Value
}

function Update-Estimate {
    $r = Get-Range
    if (-not $r) {
        $lblEstimate.ForeColor = [System.Drawing.Color]::Firebrick
        $lblEstimate.Text = 'Invalid time range'
        return
    }
    $lblEstimate.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
    $fps = Get-EffectiveFps $r
    if ($fps -le 0) { $fps = $info.Fps }
    $n = [math]::Max(1, [math]::Round($r.Length * $fps))
    $lblEstimate.Text = ('about {0} frames  ({1})' -f $n, (Format-Timecode $r.Length))
}

$onChange = { Update-Estimate }
$txtStart.Add_TextChanged($onChange)
$txtEnd.Add_TextChanged($onChange)
$numFps.Add_ValueChanged($onChange)
$numCount.Add_ValueChanged($onChange)

$modeChanged = {
    $numFps.Enabled   = $rbFps.Checked
    $numCount.Enabled = $rbCount.Checked
    Update-Estimate
}
$rbFps.Add_CheckedChanged($modeChanged)
$rbAll.Add_CheckedChanged($modeChanged)
$rbCount.Add_CheckedChanged($modeChanged)

$btnFull.Add_Click({
    $txtStart.Text = '00:00:00.000'
    $txtEnd.Text   = Format-Timecode $info.Duration
})

$cmbFormat.Add_SelectedIndexChanged({
    $isJpg = ($cmbFormat.SelectedItem -eq 'JPG')
    $numQ.Enabled     = $isJpg
    $lblQ.Enabled     = $isJpg
    $lblQHint.Enabled = $isJpg
})

$btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description  = 'Output folder for the frames'
    $fb.SelectedPath = if (Test-Path -LiteralPath $txtOut.Text) { $txtOut.Text } else { $videoDir }
    if ($fb.ShowDialog() -eq 'OK') { $txtOut.Text = $fb.SelectedPath }
})

$btnOpen.Add_Click({
    if (Test-Path -LiteralPath $script:lastOutDir) {
        Start-Process 'explorer.exe' -ArgumentList (Q $script:lastOutDir)
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250

$timer.Add_Tick({
    if (-not $script:proc) { return }

    if ($script:progressFile -and (Test-Path -LiteralPath $script:progressFile)) {
        $text = ''
        try {
            $fs = [System.IO.File]::Open($script:progressFile, 'Open', 'Read', 'ReadWrite')
            $sr = New-Object System.IO.StreamReader($fs)
            $text = $sr.ReadToEnd()
            $sr.Dispose()
            $fs.Dispose()
        } catch { }

        if ($text) {
            $us = 0.0
            $m = [regex]::Matches($text, 'out_time_us=(\d+)')
            if ($m.Count -eq 0) { $m = [regex]::Matches($text, 'out_time_ms=(\d+)') }
            if ($m.Count -gt 0) { $us = [double]$m[$m.Count - 1].Groups[1].Value }

            $frames = 0
            $mf = [regex]::Matches($text, 'frame=(\d+)')
            if ($mf.Count -gt 0) { $frames = [int]$mf[$mf.Count - 1].Groups[1].Value }

            if ($script:totalLength -gt 0) {
                $pct = [int][math]::Min(100, ($us / 1e6) / $script:totalLength * 100)
                $bar.Value = [math]::Max(0, $pct)
            }
            $lblStatus.Text = ('Converting ...   {0} frames   {1} %' -f $frames, $bar.Value)
        }
    }

    if ($script:proc.HasExited) {
        $timer.Stop()
        $exit = $script:proc.ExitCode
        $err  = ''
        try { $err = $script:proc.StandardError.ReadToEnd() } catch { }
        $script:proc    = $null
        $script:running = $false

        if ($script:progressFile -and (Test-Path -LiteralPath $script:progressFile)) {
            Remove-Item -LiteralPath $script:progressFile -Force -ErrorAction SilentlyContinue
        }

        $btnStart.Text   = 'Start'
        $btnOpen.Enabled = $true

        if ($script:cancelled) {
            $bar.Value = 0
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatus.Text = 'Cancelled.'
        }
        elseif ($exit -eq 0) {
            $bar.Value = 100
            $count = @(Get-ChildItem -LiteralPath $script:lastOutDir -Filter $script:outFilter -File -ErrorAction SilentlyContinue).Count
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
            $lblStatus.Text = ('Done - {0} frames written to {1}' -f $count, $script:lastOutDir)
        }
        else {
            $bar.Value = 0
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatus.Text = "ffmpeg failed with exit code $exit"
            if ($err) { Show-Info "ffmpeg reported:`n`n$err" 'Error' }
        }
    }
})

$btnStart.Add_Click({

    if ($script:running) {
        $script:cancelled = $true
        try { $script:proc.Kill() } catch { }
        return
    }

    $range = Get-Range
    if (-not $range) {
        Show-Info ("Start and end time are not valid." + [Environment]::NewLine + [Environment]::NewLine +
                   "Accepted formats: hh:mm:ss.ms, mm:ss or plain seconds." + [Environment]::NewLine +
                   "The end must be after the start and within the video duration.") 'Warning'
        return
    }

    $outDir = $txtOut.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = $videoDir }
    if ($chkSub.Checked) { $outDir = Join-Path $outDir ($videoName + '_frames') }

    try {
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    } catch {
        Show-Info "The output folder could not be created:`n$($_.Exception.Message)" 'Error'
        return
    }

    $ext    = if ($cmbFormat.SelectedItem -eq 'PNG') { 'png' } else { 'jpg' }
    $prefix = $txtPrefix.Text
    if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'frame_' }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $prefix = $prefix.Replace($c, '_') }

    $script:outFilter  = "$prefix*.$ext"
    $script:lastOutDir = $outDir

    $existing = @(Get-ChildItem -LiteralPath $outDir -Filter $script:outFilter -File -ErrorAction SilentlyContinue).Count
    if ($existing -gt 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "This folder already contains $existing images matching the same name pattern." + [Environment]::NewLine +
            "They will be overwritten. Continue?",
            $AppTitle, 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }

    $fps     = Get-EffectiveFps $range
    $filters = @()
    if ($fps -gt 0)        { $filters += ('fps={0}' -f $fps.ToString('0.######', $Inv)) }
    if ($numW.Value -gt 0) { $filters += ('scale={0}:-2:flags=lanczos' -f [int]$numW.Value) }

    $script:progressFile = Join-Path $env:TEMP ('ctf_' + [guid]::NewGuid().ToString('N') + '.txt')
    $outPattern = Join-Path $outDir ($prefix + '%05d.' + $ext)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('-hide_banner -nostdin -y -loglevel error -nostats')
    [void]$sb.Append(' -progress ' + (Q $script:progressFile))
    [void]$sb.Append(' -ss ' + $range.Start.ToString('0.######', $Inv))
    [void]$sb.Append(' -i ' + (Q $videoPath))
    [void]$sb.Append(' -t ' + $range.Length.ToString('0.######', $Inv))
    [void]$sb.Append(' -an -sn -dn')
    if ($filters.Count -gt 0) { [void]$sb.Append(' -vf ' + (Q ($filters -join ','))) }
    if ($ext -eq 'jpg')       { [void]$sb.Append(' -q:v ' + [int]$numQ.Value) }
    [void]$sb.Append(' -start_number 1 ' + (Q $outPattern))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName              = $ffmpegPath
    $psi.Arguments             = $sb.ToString()
    $psi.UseShellExecute       = $false
    $psi.CreateNoWindow        = $true
    $psi.RedirectStandardError = $true

    try {
        $script:proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Show-Info "ffmpeg could not be started:`n$($_.Exception.Message)" 'Error'
        return
    }

    $script:running      = $true
    $script:cancelled    = $false
    $script:totalLength  = $range.Length
    $bar.Value           = 0
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Text      = 'Converting ...'
    $btnStart.Text       = 'Cancel'
    $btnOpen.Enabled     = $false
    $timer.Start()
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    if ($script:running -and $script:proc) {
        $script:cancelled = $true
        try { $script:proc.Kill() } catch { }
    }
    $timer.Stop()
})

Update-Estimate
[void]$form.ShowDialog()
$form.Dispose()
