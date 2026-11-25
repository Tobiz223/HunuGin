# Global F6: closes the Koks window from any application. Exits by itself when the window is gone.
param([string]$Prefix = 'Koks')
Add-Type @'
using System; using System.Text; using System.Threading; using System.Runtime.InteropServices;
public static class KoksKey {
  delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w, l; public uint t; public int x, y; }
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport("user32.dll")] static extern bool PeekMessage(out MSG m, IntPtr h, uint a, uint b, uint r);
  // Chrome app windows only: an ordinary tab with the same title ends with " - Google Chrome".
  static int Find(string prefix, bool close) {
    int n = 0;
    EnumWindows((h, p) => {
      var s = new StringBuilder(300); GetClassName(h, s, 300);
      if (!s.ToString().StartsWith("Chrome_WidgetWin") || !IsWindowVisible(h)) return true;
      s.Length = 0; GetWindowText(h, s, 300); var t = s.ToString();
      if (t.StartsWith(prefix) && !t.EndsWith("Google Chrome")) { n++; if (close) PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
      return true;
    }, IntPtr.Zero);
    return n;
  }
  public static string Run(string prefix) {
    if (!RegisterHotKey(IntPtr.Zero, 1, 0x4000, 0x75)) return "F6 is already taken"; // MOD_NOREPEAT, VK_F6
    Console.WriteLine("ready");
    try {
      bool seen = false; int missing = 0;
      for (int i = 0; ; i++) {
        MSG m;
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) if (m.m == 0x0312) Find(prefix, true);
        if (i % 20 == 0) { // every second
          if (Find(prefix, false) > 0) { seen = true; missing = 0; }
          else if (++missing > (seen ? 2 : 30)) return "window closed";
        }
        Thread.Sleep(50);
      }
    } finally { UnregisterHotKey(IntPtr.Zero, 1); }
  }
}
'@
[KoksKey]::Run($Prefix)
