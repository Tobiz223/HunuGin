# Fallback system-sound capture (WASAPI loopback) for the Koks page.
# Listens on localhost only, requires the one-time token from start.bat, and captures only while the page is connected.
param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Token, [string]$Prefix = 'Koks')
Add-Type @'
using System; using System.Net; using System.Net.WebSockets; using System.Runtime.InteropServices; using System.Text; using System.Threading;

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IntPtr list);
  [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
  [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioClient {
  [PreserveSig] int Initialize(int mode, uint flags, long duration, long period, IntPtr format, IntPtr session);
  [PreserveSig] int GetBufferSize(out uint n);
  [PreserveSig] int GetStreamLatency(out long n);
  [PreserveSig] int GetCurrentPadding(out uint n);
  [PreserveSig] int IsFormatSupported(int mode, IntPtr format, out IntPtr closest);
  [PreserveSig] int GetMixFormat(out IntPtr format);
  [PreserveSig] int GetDevicePeriod(out long def, out long min);
  [PreserveSig] int Start();
  [PreserveSig] int Stop();
  [PreserveSig] int Reset();
  [PreserveSig] int SetEventHandle(IntPtr h);
  [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioCaptureClient {
  [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong pos, out ulong qpc);
  [PreserveSig] int ReleaseBuffer(uint frames);
  [PreserveSig] int GetNextPacketSize(out uint frames);
}

public static class KoksAudio {
  delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  static bool WindowOpen(string prefix) {
    bool found = false;
    EnumWindows((h, p) => {
      var s = new StringBuilder(300); GetClassName(h, s, 300);
      if (!s.ToString().StartsWith("Chrome_WidgetWin")) return true;
      s.Length = 0; GetWindowText(h, s, 300); var t = s.ToString();
      if (t.StartsWith(prefix) && !t.EndsWith("Google Chrome")) found = true;
      return !found;
    }, IntPtr.Zero);
    return found;
  }

  static IMMDeviceEnumerator Enumerator() {
    return (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
  }
  static void Check(int hr, string what) { if (hr < 0) throw new Exception(what + " 0x" + hr.ToString("X8")); }
  static string DefaultId() {
    IMMDevice d; string id;
    return Enumerator().GetDefaultAudioEndpoint(0, 0, out d) < 0 || d.GetId(out id) < 0 ? null : id;
  }
  static IAudioClient Open(out IAudioCaptureClient cap, out string id) {
    IMMDevice dev; Check(Enumerator().GetDefaultAudioEndpoint(0, 0, out dev), "no output device");
    Check(dev.GetId(out id), "device id");
    Guid g = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"); object o;
    Check(dev.Activate(ref g, 23, IntPtr.Zero, out o), "activate");
    var client = (IAudioClient)o;
    IntPtr f = Marshal.AllocHGlobal(18); // WAVEFORMATEX: 16-bit PCM, mono, 16 kHz; Windows converts
    try {
      Marshal.WriteInt16(f, 0, 1); Marshal.WriteInt16(f, 2, 1); Marshal.WriteInt32(f, 4, 16000); Marshal.WriteInt32(f, 8, 32000);
      Marshal.WriteInt16(f, 12, 2); Marshal.WriteInt16(f, 14, 16); Marshal.WriteInt16(f, 16, 0);
      // LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY
      Check(client.Initialize(0, 0x00020000u | 0x80000000u | 0x08000000u, 5000000, 0, f, IntPtr.Zero), "initialize");
    } finally { Marshal.FreeHGlobal(f); }
    g = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
    Check(client.GetService(ref g, out o), "capture service");
    cap = (IAudioCaptureClient)o;
    Check(client.Start(), "start");
    return client;
  }
  static void Send(WebSocket ws, byte[] b, int n, WebSocketMessageType t) {
    if (!ws.SendAsync(new ArraySegment<byte>(b, 0, n), t, true, CancellationToken.None).Wait(5000)) throw new TimeoutException();
  }
  static void Text(WebSocket ws, string s) { var b = Encoding.UTF8.GetBytes(s); Send(ws, b, b.Length, WebSocketMessageType.Text); }

  static void Serve(WebSocket ws) {
    // A pending receive is how a closed page is noticed.
    var recv = ws.ReceiveAsync(new ArraySegment<byte>(new byte[256]), CancellationToken.None);
    var chunk = new byte[3200]; int fill = 0;
    while (ws.State == WebSocketState.Open && !recv.IsCompleted) {
      IAudioClient client = null; IAudioCaptureClient cap = null; string id = null;
      try {
        client = Open(out cap, out id);
        Text(ws, "ok");
        int idle = 0, tick = 0;
        while (ws.State == WebSocketState.Open && !recv.IsCompleted) {
          bool got = false; uint n;
          Check(cap.GetNextPacketSize(out n), "device lost");
          while (n > 0) {
            IntPtr p; uint frames, flags; ulong a, q;
            Check(cap.GetBuffer(out p, out frames, out flags, out a, out q), "device lost");
            int bytes = (int)frames * 2; var buf = new byte[bytes];
            if ((flags & 2) == 0) Marshal.Copy(p, buf, 0, bytes); // 2 = silent
            cap.ReleaseBuffer(frames); got = true;
            for (int i = 0; i < bytes; ) {
              int c = Math.Min(bytes - i, chunk.Length - fill);
              Buffer.BlockCopy(buf, i, chunk, fill, c); fill += c; i += c;
              if (fill == chunk.Length) { Send(ws, chunk, fill, WebSocketMessageType.Binary); fill = 0; }
            }
            Check(cap.GetNextPacketSize(out n), "device lost");
          }
          // Loopback delivers nothing while the PC is silent; send silence so the speech recognizer sees the pause.
          idle = got ? 0 : idle + 1;
          if (idle >= 5) { Array.Clear(chunk, fill, chunk.Length - fill); Send(ws, chunk, chunk.Length, WebSocketMessageType.Binary); fill = 0; idle = 0; }
          if (++tick % 100 == 0 && DefaultId() != id) break; // output device switched: reopen
          Thread.Sleep(20);
        }
      } catch (Exception e) {
        if (ws.State != WebSocketState.Open) return;
        Text(ws, "err " + e.Message);
        Thread.Sleep(1500); // busy or unplugged device: keep trying
      } finally {
        if (client != null) { client.Stop(); Marshal.ReleaseComObject(client); }
        if (cap != null) Marshal.ReleaseComObject(cap);
      }
    }
  }

  public static string Run(int port, string token, string prefix) {
    var l = new HttpListener(); l.Prefixes.Add("http://localhost:" + port + "/"); l.Start();
    var server = new Thread(() => {
      while (true) {
        HttpListenerContext c;
        try { c = l.GetContext(); } catch { return; }
        if (!c.Request.IsWebSocketRequest || c.Request.QueryString["t"] != token) { c.Response.StatusCode = 403; c.Response.Close(); continue; }
        var t = new Thread(() => {
          try { using (var ws = c.AcceptWebSocketAsync(null).Result.WebSocket) Serve(ws); } catch { }
        });
        t.IsBackground = true; t.Start();
      }
    });
    server.IsBackground = true; server.Start();
    Console.WriteLine("ready");
    bool seen = false; int missing = 0;
    while (true) {
      Thread.Sleep(1000);
      if (WindowOpen(prefix)) { seen = true; missing = 0; }
      else if (++missing > (seen ? 3 : 30)) { l.Stop(); return "window closed"; }
    }
  }
}
'@
[KoksAudio]::Run($Port, $Token, $Prefix)
