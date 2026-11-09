<#
.SYNOPSIS
    ram-altman.ps1 - track RAM usage and, at most once a day, tell Sam Altman
    when this PC has RAM to spare.

.DESCRIPTION
    PowerShell port of ram-altman.sh. Works on Windows (and on Linux/macOS
    with PowerShell 7, where it reads /proc/meminfo like the original).

    Quick start (status only, no configuration needed):

        irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex

    Configure it once and install a scheduled task that samples every
    five minutes:

        $env:RAM_ALTMAN_TO               = 'you@example.com'
        $env:RAM_ALTMAN_FROM             = 'you@example.com'
        $env:RAM_ALTMAN_FROM_NAME        = 'Your Name'
        $env:RAM_ALTMAN_SMTP_SERVER      = 'smtp.example.com'
        $env:RAM_ALTMAN_SMTP_PORT        = '587'
        $env:RAM_ALTMAN_SMTP_USER        = 'you@example.com'
        $env:RAM_ALTMAN_SMTP_PASS        = 'app-password'
        $env:RAM_ALTMAN_MODE             = 'install'
        irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex

    When run from a file, the default action is "run". When piped into iex,
    the default action is "status" until a recipient is configured, so a
    curious first run never emails anyone by accident.

.NOTES
    How "used" is worked out:

        used = total - available

    On Linux, available is the kernel's own MemAvailable estimate, which
    covers free memory plus reclaimable page cache and slab memory. On
    Windows, it is the "Available" figure Task Manager shows (free plus
    standby cache), falling back to free physical memory.

    One email per person per day. Please don't point this at someone who
    doesn't want it.
#>

param(
    [string]$Action = '',
    [string]$To = '',
    [string]$From = '',
    [string]$FromName = '',
    [string]$Threshold = '',
    [string]$StateDir = '',
    [string]$MemInfo = '',
    [string]$Config = '',
    [string]$SmtpServer = '',
    [string]$SmtpPort = '',
    [string]$SmtpUser = '',
    [string]$SmtpPassword = '',
    [ValidateSet('', 'true', 'false', '1', '0', 'yes', 'no', 'on', 'off')]
    [string]$SmtpSsl = '',
    [string]$Url = '',
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$DefaultUrl = 'https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1'
$TaskName = 'Ram-Altman'
$MaxLogBytes = 10 * 1024 * 1024
$LogLinesToKeep = 50000

function Test-RamAltmanWindows {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-RamAltmanDefaultStateDir {
    if ($env:RAM_ALTMAN_STATE_DIR) { return $env:RAM_ALTMAN_STATE_DIR }

    if (Test-RamAltmanWindows) {
        $base = $env:LOCALAPPDATA
        if (-not $base) {
            $base = [System.Environment]::GetFolderPath('LocalApplicationData')
        }
        return (Join-Path $base 'ram-altman')
    }

    $base = $env:XDG_STATE_HOME
    if (-not $base) {
        $base = Join-Path $HOME '.local/state'
    }
    return (Join-Path $base 'ram-altman')
}

function Format-RamAltmanGiB {
    param([double]$Kilobytes)
    return [string]::Format($InvariantCulture, '{0:F1} GiB', ($Kilobytes / 1048576))
}

function Format-RamAltmanPercent {
    param([double]$Value)
    return [string]::Format($InvariantCulture, '{0:F1}', $Value)
}

function Get-RamAltmanMemory {
    param([string]$Path = '')

    $windows = Test-RamAltmanWindows
    if (-not $Path) {
        $Path = $env:RAM_ALTMAN_MEMINFO
        if (-not $Path) { $Path = '/proc/meminfo' }
    }

    if ((-not $windows) -and (Test-Path -LiteralPath $Path)) {
        $values = @{}
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^([A-Za-z0-9_()\-]+):\s+(\d+)') {
                $values[$Matches[1]] = [double]$Matches[2]
            }
        }

        if (-not $values.ContainsKey('MemTotal') -or $values['MemTotal'] -le 0) {
            throw "could not find MemTotal in $Path"
        }

        $total = [double]$values['MemTotal']
        $free = if ($values.ContainsKey('MemFree')) { [double]$values['MemFree'] } else { 0 }
        $buffers = if ($values.ContainsKey('Buffers')) { [double]$values['Buffers'] } else { 0 }
        $cached = if ($values.ContainsKey('Cached')) { [double]$values['Cached'] } else { 0 }
        $slab = if ($values.ContainsKey('SReclaimable')) { [double]$values['SReclaimable'] } else { 0 }
        $shmem = if ($values.ContainsKey('Shmem')) { [double]$values['Shmem'] } else { 0 }

        $cache = $buffers + $cached + $slab - $shmem
        if ($cache -lt 0) { $cache = 0 }

        # Kernels older than 3.14 have no MemAvailable, so estimate it.
        if ($values.ContainsKey('MemAvailable')) {
            $available = [double]$values['MemAvailable']
        } else {
            $available = $free + $cache
        }
        if ($available -gt $total) { $available = $total }

        $used = $total - $available
        $pct = if ($total -gt 0) { $available * 100 / $total } else { 0 }

        return [pscustomobject]@{
            TotalKb     = $total
            AvailableKb = $available
            FreeKb      = $free
            CacheKb     = $cache
            UsedKb      = $used
            AvailablePct = $pct
        }
    }

    if ($windows) {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop

        $total = [double]$cs.TotalPhysicalMemory / 1024
        $free = [double]$os.FreePhysicalMemory
        $available = $free
        $cache = 0

        $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue
        if ($null -ne $perf) {
            if ($perf.PSObject.Properties['AvailableMBytes'] -and $null -ne $perf.AvailableMBytes) {
                $available = [double]$perf.AvailableMBytes * 1024
            }
            if ($perf.PSObject.Properties['CacheBytes'] -and $null -ne $perf.CacheBytes) {
                $cache = [double]$perf.CacheBytes / 1024
            }
        }

        if ($total -le 0) { throw 'could not read total physical memory' }
        if ($available -gt $total) { $available = $total }
        if ($available -lt 0) { $available = 0 }

        $used = $total - $available
        $pct = $available * 100 / $total

        return [pscustomobject]@{
            TotalKb     = $total
            AvailableKb = $available
            FreeKb      = $free
            CacheKb     = $cache
            UsedKb      = $used
            AvailablePct = $pct
        }
    }

    throw "cannot read $Path (this script needs Windows, Linux or /proc/meminfo)"
}

function Write-RamAltmanStatus {
    param($Memory)
    Write-Output ('Total:      {0}' -f (Format-RamAltmanGiB $Memory.TotalKb))
    Write-Output ('Used:       {0}' -f (Format-RamAltmanGiB $Memory.UsedKb))
    Write-Output ('Available:  {0} ({1}%)' -f (Format-RamAltmanGiB $Memory.AvailableKb), (Format-RamAltmanPercent $Memory.AvailablePct))
    Write-Output ('  Free:     {0}' -f (Format-RamAltmanGiB $Memory.FreeKb))
    Write-Output ('  Cache:    {0}' -f (Format-RamAltmanGiB $Memory.CacheKb))
}

function Test-RamAltmanOverThreshold {
    param($Memory, [int]$Percent)
    return (($Memory.AvailableKb * 100) -gt ($Percent * $Memory.TotalKb))
}

function Write-RamAltmanLog {
    param($Memory, [string]$StateDir)

    $logPath = Join-Path $StateDir 'usage.csv'
    if (-not (Test-Path -LiteralPath $logPath)) {
        [System.IO.File]::WriteAllText($logPath, "timestamp,total_kb,used_kb,available_kb,available_pct`n")
    }

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', $InvariantCulture)
    $row = [string]::Format(
        $InvariantCulture,
        '{0},{1},{2},{3},{4}',
        $timestamp,
        $Memory.TotalKb,
        $Memory.UsedKb,
        $Memory.AvailableKb,
        (Format-RamAltmanPercent $Memory.AvailablePct)
    )
    [System.IO.File]::AppendAllText($logPath, $row + "`n")

    $info = Get-Item -LiteralPath $logPath
    if ($info.Length -gt $MaxLogBytes) {
        $header = Get-Content -LiteralPath $logPath -TotalCount 1
        $tail = Get-Content -LiteralPath $logPath -Tail $LogLinesToKeep
        $tmp = "$logPath.tmp"
        [System.IO.File]::WriteAllLines($tmp, (@($header) + @($tail)))
        Move-Item -LiteralPath $tmp -Destination $logPath -Force
    }
}

# Deals out every option once, in random order, before any can come up again.
# A dry run changes nothing on disk.
function Get-RamAltmanRandomIndex {
    param(
        [string]$Name,
        [int]$Count,
        [string]$StateDir,
        [bool]$DryRun
    )

    if ($Count -le 0) { throw "no options available for $Name" }
    if ($DryRun) { return (Get-Random -Minimum 0 -Maximum $Count) }

    $bag = Join-Path $StateDir "bag_$Name"
    $lastFile = "$bag.last"

    $needsFill = $true
    if (Test-Path -LiteralPath $bag) {
        $item = Get-Item -LiteralPath $bag
        if ($item.Length -gt 0) { $needsFill = $false }
    }

    if ($needsFill) {
        $items = @(Get-Random -InputObject (0..($Count - 1)) -Count $Count)
        if ($Count -gt 1 -and (Test-Path -LiteralPath $lastFile)) {
            $last = (Get-Content -LiteralPath $lastFile -Raw).Trim()
            if ("$($items[0])" -eq $last) {
                $items = @($items[1..($Count - 1)]) + @($items[0])
            }
        }
        [System.IO.File]::WriteAllLines($bag, [string[]]$items)
    }

    $lines = @(Get-Content -LiteralPath $bag)
    if ($lines.Count -eq 0) {
        # Covers a bag that was emptied between runs.
        [System.IO.File]::WriteAllLines($bag, [string[]]@(Get-Random -InputObject (0..($Count - 1)) -Count $Count))
        $lines = @(Get-Content -LiteralPath $bag)
    }

    $next = [int]$lines[0]
    $rest = @()
    if ($lines.Count -gt 1) { $rest = @($lines[1..($lines.Count - 1)]) }
    [System.IO.File]::WriteAllLines($bag, [string[]]$rest)
    [System.IO.File]::WriteAllText($lastFile, "$next")

    # Covers the template lists being shortened after the bag was dealt.
    if ($next -lt 0 -or $next -ge $Count) {
        $next = Get-Random -Minimum 0 -Maximum $Count
    }
    return $next
}

function New-RamAltmanEmail {
    param(
        [string]$TotalText,
        [string]$AvailableText,
        [string]$PctText,
        [string]$FromName,
        [string]$StateDir,
        [bool]$DryRun
    )

    $subjects = @(
        'Good news: we found some RAM'
        'Unused RAM detected in the wild'
        'RAM sighting on my PC'
        "$AvailableText of RAM, just sitting there"
        'You missed a spot'
        'Daily RAM census: some survived'
        "$PctText% of my RAM remains at large"
        "Still not all of it, I'm afraid"
    )

    $bodies = @(
        "I'm writing to report that you appear to have missed some. This PC has $TotalText of RAM and $AvailableText of it ($PctText%) is currently available. I assume this is an oversight."
        "A routine inspection of my PC found $AvailableText of unclaimed RAM out of $TotalText. That's $PctText% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        "Daily status report:`n`n  Total RAM:     $TotalText`n  Available:     $AvailableText ($PctText%)`n  Threat level:  someone at OpenAI might notice"
        "Even with every browser tab I own open, $AvailableText of my $TotalText of RAM is still available. I'm as surprised as you are."
        "Please don't be alarmed, but there is $AvailableText of RAM on my desk that isn't in a data centre. That's $PctText% of what's installed here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $AvailableText of $TotalText up for grabs."
        "Today's forecast for my PC: clear skies, light workloads and $PctText% available memory. Expect $AvailableText of the installed $TotalText to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $AvailableText of it. Total installed: $TotalText. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $AvailableText of RAM that I'm not using, which is $PctText% of the $TotalText in this PC. I've told nobody but you and a scheduled task."
        "If $AvailableText of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the $PctText% of my memory with nothing to do."
    )

    $signoffs = @(
        'Yours in abundance,'
        'Regards from the last free RAM in the county,'
        'Hoarding responsibly,'
        'Stay allocated,'
        'Yours, with memory to spare,'
        'Kind regards,'
    )

    $subjectIndex = Get-RamAltmanRandomIndex -Name 'subject' -Count $subjects.Count -StateDir $StateDir -DryRun $DryRun
    $bodyIndex = Get-RamAltmanRandomIndex -Name 'body' -Count $bodies.Count -StateDir $StateDir -DryRun $DryRun
    $signoffIndex = Get-RamAltmanRandomIndex -Name 'signoff' -Count $signoffs.Count -StateDir $StateDir -DryRun $DryRun

    $signatureName = if ($FromName) { $FromName } else { 'A concerned RAM owner' }

    $body = @"
Hi Sam,

$($bodies[$bodyIndex])

$($signoffs[$signoffIndex])
$signatureName

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop.
"@

    return [pscustomobject]@{
        Subject = $subjects[$subjectIndex]
        Body    = $body
    }
}

function Format-RamAltmanMessage {
    param(
        [string]$Subject,
        [string]$Body,
        [string]$Recipient,
        [string]$Sender,
        [string]$SenderName
    )

    $fromHeader = if ($SenderName) { "$SenderName <$Sender>" } else { $Sender }
    $date = (Get-Date).ToString('ddd, dd MMM yyyy HH:mm:ss zzz', $InvariantCulture)

    $lines = @(
        "From: $fromHeader"
        "To: $Recipient"
        "Subject: $Subject"
        "Date: $date"
        'MIME-Version: 1.0'
        'Content-Type: text/plain; charset=UTF-8'
        'Auto-Submitted: auto-generated'
        ''
        $Body
    )
    return (($lines -join "`n") + "`n")
}

function Send-RamAltmanMessage {
    param(
        [string]$Message,
        [string]$Subject,
        [string]$Body,
        [string]$Recipient,
        [string]$Sender,
        [string]$SenderName,
        [string]$SmtpServer,
        [int]$SmtpPort,
        [string]$SmtpUser,
        [string]$SmtpPassword,
        [bool]$SmtpSsl
    )

    if ($SmtpServer) {
        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $smtp.EnableSsl = $SmtpSsl
        $smtp.Timeout = 30000
        if ($SmtpUser) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential($SmtpUser, $SmtpPassword)
        }

        $mail = New-Object System.Net.Mail.MailMessage
        if ($SenderName) {
            $mail.From = New-Object System.Net.Mail.MailAddress($Sender, $SenderName)
        } else {
            $mail.From = New-Object System.Net.Mail.MailAddress($Sender)
        }
        $mail.To.Add($Recipient)
        $mail.Subject = $Subject
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
        $mail.Body = $Body
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8
        $mail.IsBodyHtml = $false
        $mail.Headers.Add('Auto-Submitted', 'auto-generated')

        try {
            $smtp.Send($mail)
        } catch {
            throw "SMTP send failed: $($_.Exception.GetBaseException().Message)"
        } finally {
            $mail.Dispose()
            $smtp.Dispose()
        }
        return
    }

    $sendmail = Get-Command -Name sendmail -ErrorAction SilentlyContinue
    if ($null -ne $sendmail) {
        $Message | & $sendmail.Source -t -i
        if ($LASTEXITCODE -ne 0) { throw "sendmail failed with exit code $LASTEXITCODE" }
        return
    }

    $msmtp = Get-Command -Name msmtp -ErrorAction SilentlyContinue
    if ($null -ne $msmtp) {
        $Message | & $msmtp.Source -t
        if ($LASTEXITCODE -ne 0) { throw "msmtp failed with exit code $LASTEXITCODE" }
        return
    }

    $mailCommand = Get-Command -Name mail -ErrorAction SilentlyContinue
    if ($null -ne $mailCommand) {
        $Body | & $mailCommand.Source -s $Subject $Recipient
        if ($LASTEXITCODE -ne 0) { throw "mail failed with exit code $LASTEXITCODE" }
        return
    }

    throw 'no SMTP server configured and no sendmail, msmtp or mail command found'
}

function Read-RamAltmanConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        throw "cannot read config ${Path}: $($_.Exception.Message)"
    }
}

function Get-RamAltmanConfigValue {
    param($Config, [string]$Name)
    if ($null -eq $Config) { return $null }
    $property = $Config.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Resolve-RamAltmanSetting {
    param(
        $ParamValue,
        [string]$EnvName,
        $ConfigValue,
        $Default
    )

    if ($null -ne $ParamValue -and "$ParamValue" -ne '') { return $ParamValue }
    $envValue = [System.Environment]::GetEnvironmentVariable($EnvName)
    if ($null -ne $envValue -and "$envValue" -ne '') { return $envValue }
    if ($null -ne $ConfigValue -and "$ConfigValue" -ne '') { return $ConfigValue }
    return $Default
}

function ConvertTo-RamAltmanBool {
    param($Value, [bool]$Default)
    if ($null -eq $Value -or "$Value" -eq '') { return $Default }

    switch ("$Value".ToLowerInvariant()) {
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        'on' { return $true }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        'off' { return $false }
    }
    throw "invalid boolean value: $Value"
}

function Enter-RamAltmanLock {
    param([string]$Path)
    try {
        return [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        return $null
    }
}

function Protect-RamAltmanSecretFile {
    param([string]$Path)
    if (Test-RamAltmanWindows) {
        $acl = "$($env:USERNAME):(R,W)"
        & icacls.exe $Path /inheritance:r /grant:r $acl 2>$null | Out-Null
    } else {
        $chmod = Get-Command -Name chmod -ErrorAction SilentlyContinue
        if ($null -ne $chmod) {
            & $chmod.Source 600 $Path 2>$null | Out-Null
        }
    }
}

function Save-RamAltmanScript {
    param(
        [string]$ScriptPath,
        [string]$StateDir,
        [string]$Url
    )

    $saved = Join-Path $StateDir 'ram-altman.ps1'
    $sameFile = $false

    if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath)) {
        try {
            $sameFile = ([System.IO.Path]::GetFullPath($ScriptPath) -eq [System.IO.Path]::GetFullPath($saved))
        } catch {
            $sameFile = $false
        }
    }

    if ($sameFile) { return $saved }

    if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath)) {
        Copy-Item -LiteralPath $ScriptPath -Destination $saved -Force
        return $saved
    }

    $downloadUrl = if ($Url) { $Url } else { $DefaultUrl }
    Write-Host "Downloading $downloadUrl"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $saved -UseBasicParsing
    } else {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $saved
    }
    return $saved
}

function Install-RamAltmanTask {
    param([string]$ScriptPath, [string]$StateDir)

    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'Register-ScheduledTask is not available; create a scheduled task manually'
    }

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action run -StateDir "{1}"' -f $ScriptPath, $StateDir
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

    $userId = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Reports unused RAM to Sam Altman, at most once a day.' -Force | Out-Null
    } catch {
        throw "could not register the scheduled task ($($_.Exception.Message)). Try running PowerShell as your own user or as Administrator, or create it manually with: powershell.exe $arguments"
    }
}

function Install-RamAltman {
    param(
        [string]$To,
        [string]$From,
        [string]$FromName,
        [int]$Threshold,
        [string]$StateDir,
        [string]$ConfigPath,
        [string]$SmtpServer,
        [int]$SmtpPort,
        [string]$SmtpUser,
        [string]$SmtpPassword,
        [bool]$SmtpSsl,
        [string]$Url,
        [string]$ScriptPath
    )

    if (-not $To) { throw 'a recipient is required (set RAM_ALTMAN_TO or use -To)' }
    if (-not $From) { throw 'a sender is required (set RAM_ALTMAN_FROM or use -From)' }

    if (-not $SmtpServer) {
        $haveLocalMailer = (Get-Command -Name sendmail -ErrorAction SilentlyContinue) -or
            (Get-Command -Name msmtp -ErrorAction SilentlyContinue) -or
            (Get-Command -Name mail -ErrorAction SilentlyContinue)
        if (-not $haveLocalMailer) {
            throw 'configure SMTP with RAM_ALTMAN_SMTP_SERVER (and user/password if needed)'
        }
    }

    [System.IO.Directory]::CreateDirectory($StateDir) | Out-Null

    $configObject = [ordered]@{
        To           = $To
        From         = $From
        FromName     = $FromName
        Threshold    = $Threshold
        SmtpServer   = $SmtpServer
        SmtpPort     = $SmtpPort
        SmtpUser     = $SmtpUser
        SmtpPassword = $SmtpPassword
        SmtpSsl      = $SmtpSsl
        Url          = $(if ($Url) { $Url } else { $DefaultUrl })
        InstalledAt  = (Get-Date).ToString('o', $InvariantCulture)
    }

    $json = $configObject | ConvertTo-Json
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigPath, $json, $utf8)
    Protect-RamAltmanSecretFile -Path $ConfigPath

    $savedScript = Save-RamAltmanScript -ScriptPath $ScriptPath -StateDir $StateDir -Url $Url

    if (Test-RamAltmanWindows) {
        Install-RamAltmanTask -ScriptPath $savedScript -StateDir $StateDir
        Write-Output 'Installed. Ram-Altman will sample every 5 minutes and email at most once a day.'
        Write-Output "  Scheduled task: $TaskName"
    } else {
        $cron = "*/5 * * * * pwsh -NoProfile -File `"$savedScript`" -Action run -StateDir `"$StateDir`""
        Write-Output 'Installed. Add this line to your crontab (crontab -e):'
        Write-Output ''
        Write-Output "  $cron"
    }

    Write-Output "  Config:         $ConfigPath"
    Write-Output "  Usage log:      $(Join-Path $StateDir 'usage.csv')"
    Write-Output "  Script copy:    $savedScript"
    if ($SmtpPassword) {
        Write-Output ''
        Write-Output 'Note: the SMTP password is stored in the config file with user-only permissions.'
    }
}

function Uninstall-RamAltman {
    param([string]$StateDir, [bool]$Purge)

    if (Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Output "Removed scheduled task: $TaskName"
    }

    if ($Purge) {
        if (Test-Path -LiteralPath $StateDir) {
            Remove-Item -LiteralPath $StateDir -Recurse -Force
            Write-Output "Removed state directory: $StateDir"
        }
    } else {
        Write-Output "State kept in: $StateDir"
        Write-Output 'Run with -Purge to delete the log, state and config as well.'
    }
}

function Show-RamAltmanHelp {
    Write-Output @'
Ram-Altman (PowerShell)

Usage:
  ./ram-altman.ps1 [-Action run|status|dry-run|install|uninstall|test-mail|help]

Quick start from GitHub (status only, no configuration needed):
  irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex

Install a scheduled task (configure with environment variables first):
  $env:RAM_ALTMAN_TO          = 'you@example.com'
  $env:RAM_ALTMAN_FROM        = 'you@example.com'
  $env:RAM_ALTMAN_SMTP_SERVER = 'smtp.example.com'
  $env:RAM_ALTMAN_SMTP_USER   = 'you@example.com'
  $env:RAM_ALTMAN_SMTP_PASS   = 'app-password'
  $env:RAM_ALTMAN_MODE        = 'install'
  irm https://raw.githubusercontent.com/ndiuky/ram-altman/main/ram-altman.ps1 | iex

Settings (parameters win over environment variables, which win over config.json):
  RAM_ALTMAN_TO             Who receives the email              (required)
  RAM_ALTMAN_FROM           A real address you can send from    (required)
  RAM_ALTMAN_FROM_NAME      Display name                        (optional)
  RAM_ALTMAN_THRESHOLD      Email above this available percent  (default 10)
  RAM_ALTMAN_STATE_DIR      Log and state directory             (~/.local/state/ram-altman)
  RAM_ALTMAN_MEMINFO        Path to meminfo on Linux            (/proc/meminfo)
  RAM_ALTMAN_SMTP_SERVER    SMTP server                         (needed on Windows)
  RAM_ALTMAN_SMTP_PORT      SMTP port                           (default 587)
  RAM_ALTMAN_SMTP_USER      SMTP user name                      (optional)
  RAM_ALTMAN_SMTP_PASS      SMTP password                       (optional)
  RAM_ALTMAN_SMTP_SSL       Use TLS                             (default true)
  RAM_ALTMAN_MODE           Default action when piped to iex    (run/status/install)

On Windows, mail is sent through SMTP. On Linux/macOS with PowerShell 7,
sendmail, msmtp or mail are used when available.
'@
}

function Invoke-RamAltman {
    param(
        [string]$Action,
        [string]$To,
        [string]$From,
        [string]$FromName,
        [string]$Threshold,
        [string]$StateDir,
        [string]$MemInfo,
        [string]$Config,
        [string]$SmtpServer,
        [string]$SmtpPort,
        [string]$SmtpUser,
        [string]$SmtpPassword,
        [string]$SmtpSsl,
        [string]$Url,
        [bool]$Purge
    )

    $resolvedStateDir = Resolve-RamAltmanSetting -ParamValue $StateDir -EnvName 'RAM_ALTMAN_STATE_DIR' -ConfigValue $null -Default (Get-RamAltmanDefaultStateDir)

    $configPath = ''
    if ($Config) {
        $configPath = $Config
    } elseif ($env:RAM_ALTMAN_CONFIG) {
        $configPath = $env:RAM_ALTMAN_CONFIG
    } else {
        $configPath = Join-Path $resolvedStateDir 'config.json'
    }

    $cfg = Read-RamAltmanConfig -Path $configPath

    $resolvedTo = Resolve-RamAltmanSetting -ParamValue $To -EnvName 'RAM_ALTMAN_TO' -ConfigValue (Get-RamAltmanConfigValue $cfg 'To') -Default ''
    $resolvedFrom = Resolve-RamAltmanSetting -ParamValue $From -EnvName 'RAM_ALTMAN_FROM' -ConfigValue (Get-RamAltmanConfigValue $cfg 'From') -Default ''
    $resolvedFromName = Resolve-RamAltmanSetting -ParamValue $FromName -EnvName 'RAM_ALTMAN_FROM_NAME' -ConfigValue (Get-RamAltmanConfigValue $cfg 'FromName') -Default ''
    $resolvedSmtpServer = Resolve-RamAltmanSetting -ParamValue $SmtpServer -EnvName 'RAM_ALTMAN_SMTP_SERVER' -ConfigValue (Get-RamAltmanConfigValue $cfg 'SmtpServer') -Default ''
    $resolvedSmtpUser = Resolve-RamAltmanSetting -ParamValue $SmtpUser -EnvName 'RAM_ALTMAN_SMTP_USER' -ConfigValue (Get-RamAltmanConfigValue $cfg 'SmtpUser') -Default ''
    $resolvedSmtpPassword = Resolve-RamAltmanSetting -ParamValue $SmtpPassword -EnvName 'RAM_ALTMAN_SMTP_PASS' -ConfigValue (Get-RamAltmanConfigValue $cfg 'SmtpPassword') -Default ''
    $resolvedUrl = Resolve-RamAltmanSetting -ParamValue $Url -EnvName 'RAM_ALTMAN_URL' -ConfigValue (Get-RamAltmanConfigValue $cfg 'Url') -Default $DefaultUrl

    $thresholdRaw = Resolve-RamAltmanSetting -ParamValue $Threshold -EnvName 'RAM_ALTMAN_THRESHOLD' -ConfigValue (Get-RamAltmanConfigValue $cfg 'Threshold') -Default 10
    $thresholdValue = 0
    if (-not [int]::TryParse("$thresholdRaw", [ref]$thresholdValue)) {
        throw "threshold must be a whole number, got: $thresholdRaw"
    }
    if ($thresholdValue -lt 0 -or $thresholdValue -gt 100) {
        throw "threshold must be between 0 and 100, got: $thresholdValue"
    }

    $portRaw = Resolve-RamAltmanSetting -ParamValue $SmtpPort -EnvName 'RAM_ALTMAN_SMTP_PORT' -ConfigValue (Get-RamAltmanConfigValue $cfg 'SmtpPort') -Default 587
    $portValue = 0
    if (-not [int]::TryParse("$portRaw", [ref]$portValue)) {
        throw "SMTP port must be a whole number, got: $portRaw"
    }

    $sslRaw = Resolve-RamAltmanSetting -ParamValue $SmtpSsl -EnvName 'RAM_ALTMAN_SMTP_SSL' -ConfigValue (Get-RamAltmanConfigValue $cfg 'SmtpSsl') -Default $true
    $sslValue = ConvertTo-RamAltmanBool -Value $sslRaw -Default $true

    $memInfoPath = Resolve-RamAltmanSetting -ParamValue $MemInfo -EnvName 'RAM_ALTMAN_MEMINFO' -ConfigValue $null -Default '/proc/meminfo'

    $fromIex = [string]::IsNullOrEmpty($PSCommandPath)
    $resolvedAction = $Action
    $actionWasDefaulted = $false
    if (-not $resolvedAction) {
        $modeEnv = [System.Environment]::GetEnvironmentVariable('RAM_ALTMAN_MODE')
        if ($modeEnv) {
            $resolvedAction = $modeEnv
        } elseif ($fromIex -and ((-not $resolvedTo) -or (-not $resolvedFrom))) {
            # A curious first run should not accidentally email anyone.
            $resolvedAction = 'status'
            $actionWasDefaulted = $true
        } else {
            $resolvedAction = 'run'
        }
    }
    $resolvedAction = $resolvedAction.ToLowerInvariant()

    switch ($resolvedAction) {
        'status' {
            $memory = Get-RamAltmanMemory -Path $memInfoPath
            Write-RamAltmanStatus -Memory $memory
            if ($actionWasDefaulted) {
                Write-Output ''
                Write-Output 'No email settings found, so this was a status-only run.'
                Write-Output 'Set RAM_ALTMAN_TO and RAM_ALTMAN_FROM to configure it, then re-run.'
                Write-Output 'See the README or run with -Action help for details.'
            }
            return
        }

        'dry-run' {
            $memory = Get-RamAltmanMemory -Path $memInfoPath
            Write-RamAltmanStatus -Memory $memory

            if (-not (Test-RamAltmanOverThreshold -Memory $memory -Percent $thresholdValue)) {
                Write-Output "No email: available RAM is not above ${thresholdValue}%."
                return
            }

            $email = New-RamAltmanEmail `
                -TotalText (Format-RamAltmanGiB $memory.TotalKb) `
                -AvailableText (Format-RamAltmanGiB $memory.AvailableKb) `
                -PctText (Format-RamAltmanPercent $memory.AvailablePct) `
                -FromName $resolvedFromName `
                -StateDir $resolvedStateDir `
                -DryRun $true

            $sender = if ($resolvedFrom) { $resolvedFrom } else { 'sender-not-set@example.com' }
            $recipient = if ($resolvedTo) { $resolvedTo } else { 'recipient-not-set@example.com' }

            $message = Format-RamAltmanMessage `
                -Subject $email.Subject `
                -Body $email.Body `
                -Recipient $recipient `
                -Sender $sender `
                -SenderName $resolvedFromName

            Write-Output ''
            Write-Output $message
            return
        }

        'test-mail' {
            if (-not $resolvedTo) { throw 'a recipient is required (set RAM_ALTMAN_TO or use -To)' }
            if (-not $resolvedFrom) { throw 'a sender is required (set RAM_ALTMAN_FROM or use -From)' }

            [System.IO.Directory]::CreateDirectory($resolvedStateDir) | Out-Null
            $memory = Get-RamAltmanMemory -Path $memInfoPath

            $email = New-RamAltmanEmail `
                -TotalText (Format-RamAltmanGiB $memory.TotalKb) `
                -AvailableText (Format-RamAltmanGiB $memory.AvailableKb) `
                -PctText (Format-RamAltmanPercent $memory.AvailablePct) `
                -FromName $resolvedFromName `
                -StateDir $resolvedStateDir `
                -DryRun $true

            $message = Format-RamAltmanMessage `
                -Subject $email.Subject `
                -Body $email.Body `
                -Recipient $resolvedTo `
                -Sender $resolvedFrom `
                -SenderName $resolvedFromName

            Send-RamAltmanMessage `
                -Message $message `
                -Subject $email.Subject `
                -Body $email.Body `
                -Recipient $resolvedTo `
                -Sender $resolvedFrom `
                -SenderName $resolvedFromName `
                -SmtpServer $resolvedSmtpServer `
                -SmtpPort $portValue `
                -SmtpUser $resolvedSmtpUser `
                -SmtpPassword $resolvedSmtpPassword `
                -SmtpSsl $sslValue

            Write-Output "Test email sent to $resolvedTo."
            return
        }

        'install' {
            Install-RamAltman `
                -To $resolvedTo `
                -From $resolvedFrom `
                -FromName $resolvedFromName `
                -Threshold $thresholdValue `
                -StateDir $resolvedStateDir `
                -ConfigPath $configPath `
                -SmtpServer $resolvedSmtpServer `
                -SmtpPort $portValue `
                -SmtpUser $resolvedSmtpUser `
                -SmtpPassword $resolvedSmtpPassword `
                -SmtpSsl $sslValue `
                -Url $resolvedUrl `
                -ScriptPath $PSCommandPath
            return
        }

        'uninstall' {
            Uninstall-RamAltman -StateDir $resolvedStateDir -Purge $Purge
            return
        }

        'help' {
            Show-RamAltmanHelp
            return
        }

        'run' {
            if (-not $resolvedTo) { throw 'a recipient is required (set RAM_ALTMAN_TO or use -To)' }
            if (-not $resolvedFrom) { throw 'a sender is required (set RAM_ALTMAN_FROM or use -From)' }

            [System.IO.Directory]::CreateDirectory($resolvedStateDir) | Out-Null

            $lock = Enter-RamAltmanLock -Path (Join-Path $resolvedStateDir 'lock')
            if ($null -eq $lock) {
                # Another run is already doing the rounds.
                return
            }

            try {
                $memory = Get-RamAltmanMemory -Path $memInfoPath
                Write-RamAltmanLog -Memory $memory -StateDir $resolvedStateDir

                if (-not (Test-RamAltmanOverThreshold -Memory $memory -Percent $thresholdValue)) {
                    return
                }

                $today = (Get-Date).ToString('yyyy-MM-dd', $InvariantCulture)
                $lastSentFile = Join-Path $resolvedStateDir 'last_sent'
                $lastSent = ''
                if (Test-Path -LiteralPath $lastSentFile) {
                    $lastSent = (Get-Content -LiteralPath $lastSentFile -Raw).Trim()
                }
                if ($lastSent -eq $today) { return }

                $email = New-RamAltmanEmail `
                    -TotalText (Format-RamAltmanGiB $memory.TotalKb) `
                    -AvailableText (Format-RamAltmanGiB $memory.AvailableKb) `
                    -PctText (Format-RamAltmanPercent $memory.AvailablePct) `
                    -FromName $resolvedFromName `
                    -StateDir $resolvedStateDir `
                    -DryRun $false

                $message = Format-RamAltmanMessage `
                    -Subject $email.Subject `
                    -Body $email.Body `
                    -Recipient $resolvedTo `
                    -Sender $resolvedFrom `
                    -SenderName $resolvedFromName

                Send-RamAltmanMessage `
                    -Message $message `
                    -Subject $email.Subject `
                    -Body $email.Body `
                    -Recipient $resolvedTo `
                    -Sender $resolvedFrom `
                    -SenderName $resolvedFromName `
                    -SmtpServer $resolvedSmtpServer `
                    -SmtpPort $portValue `
                    -SmtpUser $resolvedSmtpUser `
                    -SmtpPassword $resolvedSmtpPassword `
                    -SmtpSsl $sslValue

                # Recorded only after a successful send, so a failure gets retried.
                [System.IO.File]::WriteAllText($lastSentFile, $today)
            } finally {
                $lock.Dispose()
            }
            return
        }

        default {
            throw "unknown action: $resolvedAction (try -Action help)"
        }
    }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
$failed = $false

try {
    Invoke-RamAltman `
        -Action $Action `
        -To $To `
        -From $From `
        -FromName $FromName `
        -Threshold $Threshold `
        -StateDir $StateDir `
        -MemInfo $MemInfo `
        -Config $Config `
        -SmtpServer $SmtpServer `
        -SmtpPort $SmtpPort `
        -SmtpUser $SmtpUser `
        -SmtpPassword $SmtpPassword `
        -SmtpSsl $SmtpSsl `
        -Url $Url `
        -Purge ([bool]$Purge)
} catch {
    $failed = $true
    $ErrorActionPreference = $previousErrorActionPreference
    Write-Error ("ram-altman: " + $_.Exception.Message) -ErrorAction Continue
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

# Do not call exit when this came through "irm | iex": that would take the
# caller's session down with it. Only a script file exits with an error code.
if ($failed -and $PSCommandPath) { exit 1 }
