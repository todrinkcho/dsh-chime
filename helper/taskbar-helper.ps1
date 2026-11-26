#requires -Version 5.1
<#
  Taskbar badge + chime helper for the DSH desktop shell.

  Started by the Host plugin half (@todrink/dsh-chime) as a long-lived
  background process. It watches a small JSON command file written by the
  plugin and reflects it on the DeepSeek Harness taskbar button:

    mode "done" -> green overlay badge (one-shot: cleared once the window is read)
    mode "ask"  -> amber overlay badge (persistent: hidden while the window is
                   focused, re-shown when the user looks away without answering)
    mode "none" -> no badge

  Windows 11 draws an overlay badge on the upper-right corner of the taskbar
  button; that position belongs to Explorer, not to the application.

  The helper exits by itself as soon as its parent Host process disappears, so
  it never outlives the harness.
#>
param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$CommandFile,
  [Parameter(Mandatory = $true)][string]$DoneWav,
  [Parameter(Mandatory = $true)][string]$AskWav,
  [string]$ProcessName = 'DeepSeek Harness',
  [int]$PollMs = 350,
  # Debug aid: keep the badge visible even while the window is focused.
  [switch]$IgnoreFocus
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
$drawingAssembly = [System.Drawing.Bitmap].Assembly.Location

$csharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

public sealed class BadgeWindow {
    public IntPtr Handle;
    public int Pid;
    public string Title;
}

public static class TaskbarBadge {
    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3 {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow(IntPtr hwnd, bool fFullscreen);
        void SetProgressValue(IntPtr hwnd, ulong ullCompleted, ulong ullTotal);
        void SetProgressState(IntPtr hwnd, int tbpFlags);
        void RegisterTab(IntPtr hwndTab, IntPtr hwndMDI);
        void UnregisterTab(IntPtr hwndTab);
        void SetTabOrder(IntPtr hwndTab, IntPtr hwndInsertBefore);
        void SetTabActive(IntPtr hwndTab, IntPtr hwndMDI, uint dwReserved);
        void ThumbBarAddButtons(IntPtr hwnd, uint cButtons, IntPtr pButtons);
        void ThumbBarUpdateButtons(IntPtr hwnd, uint cButtons, IntPtr pButtons);
        void ThumbBarSetImageList(IntPtr hwnd, IntPtr himl);
        void SetOverlayIcon(IntPtr hwnd, IntPtr hIcon, [MarshalAs(UnmanagedType.LPWStr)] string pszDescription);
        void SetThumbnailTooltip(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string pszTip);
        void SetThumbnailClip(IntPtr hwnd, IntPtr prcClip);
    }

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnkOuter, uint dwClsContext, ref Guid riid, out IntPtr ppv);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern bool PlaySound(string sound, IntPtr module, uint flags);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private const uint SND_FILENAME = 0x00020000;
    private const uint SND_ASYNC = 0x0001;
    private const uint SND_NODEFAULT = 0x0002;

    public static int ForegroundPid() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return 0;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return unchecked((int)pid);
    }

    /** Largest visible, titled top-level window owned by a process with this name. */
    public static BadgeWindow FindWindow(string processName) {
        List<IntPtr> handles = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;
            if (GetWindowTextLength(hWnd) == 0) return true;
            handles.Add(hWnd);
            return true;
        }, IntPtr.Zero);

        BadgeWindow best = null;
        long bestArea = -1;
        foreach (IntPtr hWnd in handles) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            string name;
            try { name = Process.GetProcessById((int)pid).ProcessName; } catch { continue; }
            if (!string.Equals(name, processName, StringComparison.OrdinalIgnoreCase)) continue;

            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) continue;
            long area = (long)(rect.Right - rect.Left) * (rect.Bottom - rect.Top);
            StringBuilder title = new StringBuilder(GetWindowTextLength(hWnd) + 2);
            GetWindowText(hWnd, title, title.Capacity);
            if (area > bestArea) {
                bestArea = area;
                best = new BadgeWindow { Handle = hWnd, Pid = unchecked((int)pid), Title = title.ToString() };
            }
        }
        return best;
    }

    public static bool Alive(IntPtr hwnd) {
        return hwnd != IntPtr.Zero && IsWindow(hwnd);
    }

    private static ITaskbarList3 cached;

    private static ITaskbarList3 Create() {
        if (cached != null) return cached;
        Guid clsid = new Guid("56FDF344-FD6D-11d0-958A-006097C9A090");
        Guid iid = new Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf");
        IntPtr p;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref iid, out p);
        if (hr != 0) throw new COMException("CoCreateInstance(ITaskbarList3) failed", hr);
        try {
            ITaskbarList3 taskbar = (ITaskbarList3)Marshal.GetObjectForIUnknown(p);
            taskbar.HrInit();
            cached = taskbar;
            return taskbar;
        } finally {
            Marshal.Release(p);
        }
    }

    /** Drop the cached COM object so the next call re-creates it (Explorer restart). */
    public static void Reset() {
        cached = null;
    }

    public static void SetOverlay(IntPtr hwnd, IntPtr hIcon, string description) {
        Create().SetOverlayIcon(hwnd, hIcon, description);
    }

    /** A filled dot with a soft light ring, sized for the 16px taskbar overlay slot. */
    public static IntPtr MakeDot(int argbFill, int argbRing) {
        Bitmap bitmap = new Bitmap(32, 32);
        using (Graphics graphics = Graphics.FromImage(bitmap)) {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            using (SolidBrush ring = new SolidBrush(Color.FromArgb(argbRing))) {
                graphics.FillEllipse(ring, 1, 1, 30, 30);
            }
            using (SolidBrush fill = new SolidBrush(Color.FromArgb(argbFill))) {
                graphics.FillEllipse(fill, 4, 4, 24, 24);
            }
        }
        return bitmap.GetHicon();
    }

    public static bool Chime(string path) {
        if (string.IsNullOrEmpty(path)) return false;
        return PlaySound(path, IntPtr.Zero, SND_FILENAME | SND_ASYNC | SND_NODEFAULT);
    }
}
'@

Add-Type -TypeDefinition $csharp -ReferencedAssemblies $drawingAssembly

$greenIcon = [TaskbarBadge]::MakeDot(([System.Drawing.Color]::FromArgb(255, 34, 197, 94)).ToArgb(), ([System.Drawing.Color]::White).ToArgb())
$amberIcon = [TaskbarBadge]::MakeDot(([System.Drawing.Color]::FromArgb(255, 245, 165, 36)).ToArgb(), ([System.Drawing.Color]::White).ToArgb())

$helperLog = Join-Path (Split-Path -Parent $CommandFile) 'helper.log'
function Write-HelperLog([string]$message) {
  try {
    if ((Test-Path -LiteralPath $helperLog) -and (Get-Item -LiteralPath $helperLog).Length -gt 262144) {
      Set-Content -LiteralPath $helperLog -Value '' -Encoding utf8
    }
    $stamp = (Get-Date).ToString('s')
    Add-Content -LiteralPath $helperLog -Value "$stamp $message" -Encoding utf8
  } catch { }
}

Write-HelperLog "start pid=$PID parent=$ParentPid processName=$ProcessName"

# Badge state. `pending` is what the taskbar button should show while the window
# is not focused; `oneshot` badges are consumed the first time it is focused.
$mode = 'none'
$pending = $null          # $null | 'done' | 'ask'
$lastSeq = [long]-1
$shown = $null

$target = $null
$targetAt = [datetime]::MinValue
$focused = $false
$noWindowLogged = $false
$parentCheckedAt = [datetime]::MinValue

function Get-CommandState {
  if (-not (Test-Path -LiteralPath $CommandFile)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $CommandFile -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Apply-Badge {
  if ($null -eq $target -or -not [TaskbarBadge]::Alive($target.Handle)) {
    if ($null -ne $pending -and -not $noWindowLogged) {
      Write-HelperLog "no taskbar window for badge '$pending' (is the desktop shell running?)"
      $script:noWindowLogged = $true
    }
    return
  }
  $want = $null
  if ((-not $focused) -or $IgnoreFocus) { $want = $pending }
  if ($want -eq $shown) { return }
  try {
    switch ($want) {
      'done' {
        [TaskbarBadge]::SetOverlay($target.Handle, $greenIcon, 'Done')
      }
      'ask' {
        [TaskbarBadge]::SetOverlay($target.Handle, $amberIcon, 'Waiting for your answer')
      }
      default {
        [TaskbarBadge]::SetOverlay($target.Handle, [IntPtr]::Zero, '')
      }
    }
    $script:shown = $want
    Write-HelperLog "overlay '$want' hwnd=$($target.Handle) pid=$($target.Pid)"
  } catch {
    Write-HelperLog "overlay '$want' failed: $($_.Exception.Message)"
    # Explorer restarted (or the COM object died): drop it and re-acquire next tick.
    [TaskbarBadge]::Reset()
    $script:target = $null
  }
}

while ($true) {
  try {
    $now = Get-Date

    # Parent liveness: the Host process owns this helper's lifetime.
    if (($now - $parentCheckedAt).TotalSeconds -ge 3) {
      $parentCheckedAt = $now
      $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
      if ($null -eq $parent) { break }
    }

    # Locate (or relocate) the shell window.
    if ($null -eq $target -or -not [TaskbarBadge]::Alive($target.Handle) -or ($now - $targetAt).TotalSeconds -ge 5) {
      $targetAt = $now
      $found = [TaskbarBadge]::FindWindow($ProcessName)
      if ($null -ne $found) {
        if ($null -eq $target -or $target.Handle -ne $found.Handle) {
          Write-HelperLog "window hwnd=$($found.Handle) pid=$($found.Pid)"
          $shown = $null
          $script:noWindowLogged = $false
        }
        $target = $found
      } else {
        if ($null -ne $target) { Write-HelperLog 'window lost' }
        $target = $null
      }
    }

    # Command file: react once per sequence number.
    $command = Get-CommandState
    if ($null -ne $command -and $null -ne $command.seq -and [long]$command.seq -ne $lastSeq) {
      $lastSeq = [long]$command.seq
      $mode = [string]$command.mode
      switch ($mode) {
        'done' { $pending = 'done' }
        'ask' { $pending = 'ask' }
        default { $pending = $null }
      }
      $chime = ''
      if ($command.tone -eq 'done') { $chime = [TaskbarBadge]::Chime($DoneWav) }
      elseif ($command.tone -eq 'ask') { $chime = [TaskbarBadge]::Chime($AskWav) }
      Write-HelperLog "command seq=$lastSeq mode=$mode tone=$($command.tone) chime=$chime"
      # A "done" badge the user already has in front of them is read immediately.
      if ($mode -eq 'done' -and $focused -and -not $IgnoreFocus) { $pending = $null }
    }

    # Focus tracking: focusing reads the badge; looking away restores a question.
    $pidNow = [TaskbarBadge]::ForegroundPid()
    $isFocused = ($null -ne $target) -and ($pidNow -ne 0) -and ($pidNow -eq $target.Pid)
    if ($isFocused -ne $focused) {
      $focused = $isFocused
      Write-HelperLog "focused=$focused"
      if ($focused -and $pending -eq 'done') { $pending = $null }
    }

    Apply-Badge
  } catch {
    # A transient failure (window recreation, COM hiccup) must not kill the loop.
    Write-HelperLog "loop error: $($_.Exception.Message)"
    Start-Sleep -Milliseconds 500
  }
  Start-Sleep -Milliseconds $PollMs
}

if ($null -ne $target -and [TaskbarBadge]::Alive($target.Handle)) {
  try { [TaskbarBadge]::SetOverlay($target.Handle, [IntPtr]::Zero, '') } catch { }
}

