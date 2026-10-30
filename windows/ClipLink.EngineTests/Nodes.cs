using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Engine;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.EngineTests;

// What the engine writes to the console (its log), kept so a test can check what
// it did and did not do. Tests that read it run one at a time.
internal static class LogTap
{
    private sealed class Writer : TextWriter
    {
        private readonly StringBuilder line = new();
        public override Encoding Encoding => Encoding.UTF8;

        public override void Write(char value)
        {
            lock (Lines)
            {
                if (value == '\n') { Lines.Add(line.ToString()); line.Clear(); }
                else if (value != '\r') line.Append(value);
            }
        }
    }

    private static readonly List<string> Lines = new();
    private static bool installed;

    public static void Start()
    {
        lock (Lines)
        {
            if (!installed) { Console.SetOut(new Writer()); installed = true; }
            Lines.Clear();
        }
    }

    public static bool Contains(string text)
    {
        lock (Lines) { return Lines.Any(line => line.Contains(text)); }
    }

    public static List<string> With(string text)
    {
        lock (Lines) { return Lines.Where(line => line.Contains(text)).ToList(); }
    }
}

internal static class Wait
{
    // Polls until the condition holds. False if it didn't within the time.
    public static async Task<bool> Until(Func<bool> condition, int timeoutMs = 8000)
    {
        var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < until)
        {
            if (condition()) return true;
            await Task.Delay(25);
        }
        return condition();
    }

    // Time for something that should NOT happen to have happened.
    public static Task Quiet(int ms = 600) => Task.Delay(ms);
}

// The files a node keeps under %APPDATA%\ClipboardDaemon all have its label in
// their name.
internal static class TestData
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClipboardDaemon");

    public static readonly DateTime Base = new(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc);

    public static string NewLabel(string name) => $"zz-e2e-{name}-{Guid.NewGuid():N}"[..28];

    public static void Delete(string label)
    {
        foreach (string path in Directory.EnumerateFileSystemEntries(Dir, $"*{label}*"))
        {
            try
            {
                if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
                else File.Delete(path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
        try { Directory.Delete(Path.Combine(Path.GetTempPath(), "ClipLink", label), recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    public static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    // Entry n minutes after Base, text "text <n>"-ish, signed by identity.
    public static ClipboardEntry Entry(DeviceIdentity identity, string text, int minute) =>
        SigningService.Sign(new ClipboardEntry(text, "text", identity.GetPublicKey(), Base.AddMinutes(minute)), identity);
}

// A real engine on loopback, with its own files. Seed its history (and what it
// deleted) before Start, as if it had run before.
internal sealed class TestNode : IDisposable
{
    public string Label { get; }
    public int Port { get; }
    public DeviceIdentity Identity { get; }
    public string Id { get; }
    public ClipLinkEngine? Engine { get; private set; }

    public TestNode(string name)
    {
        Label = TestData.NewLabel(name);
        Port = TestData.FreePort();
        Identity = new DeviceIdentity(Label);
        Id = Identity.GetPublicKey();
    }

    // An entry made by this node.
    public ClipboardEntry Make(string text, int minute) => TestData.Entry(Identity, text, minute);

    public void SeedHistory(params ClipboardEntry[] entries) =>
        File.WriteAllText(Path.Combine(TestData.Dir, $"history{Label}.json"), JsonSerializer.Serialize(entries.ToList()));

    // Keys deleted earlier, the oldest first (as DeletedEntries keeps them).
    public void SeedDeleted(params string[] keys)
    {
        long at = 1_000;
        File.WriteAllText(Path.Combine(TestData.Dir, $"deleted{Label}.json"),
            JsonSerializer.Serialize(keys.Select(key => new DeletedEntry(key, at++)).ToList()));
    }

    // protocol 1: stands in for a build from before protocol 2.
    public ClipLinkEngine Start(int protocol = HandshakeMessage.CurrentProtocol)
    {
        Engine?.Dispose();
        Engine = new ClipLinkEngine();
        Assert.True(Engine.Start(Label, Port, new EngineOptions { WatchClipboard = false, LoopbackOnly = true, Protocol = protocol }));
        return Engine;
    }

    public void Trust(string deviceId) => Assert.True(Engine!.TrustPairingPayload(deviceId));

    // What was put on this PC's clipboard, in order.
    public List<string> Applied => ClipboardSync.ByLabel[Label].Applied.Select(applied => applied.Content).ToList();

    // The Synced page's items, in order: the text of each.
    public List<string> Texts => Engine!.GetHistory().Select(item => item.TextPreview ?? "").ToList();

    public bool Has(ClipboardEntry entry) => Engine!.GetHistory().Any(item => item.Key == entry.Key());

    public void Dispose()
    {
        Engine?.Dispose();
        TestData.Delete(Label);
    }
}

// A peer played by the test: it speaks the handshake and the encryption like
// the app (the same PeerConnection), but what it sends and what it does with
// what it gets is up to the test.
internal sealed class RawPeer : IDisposable
{
    private readonly string label;
    private readonly List<Envelope> inbox = new();
    private PeerConnection? conn;

    public DeviceIdentity Identity { get; }
    public string Id { get; }

    public RawPeer(string name)
    {
        label = TestData.NewLabel(name);
        Identity = new DeviceIdentity(label);
        Id = Identity.GetPublicKey();
    }

    public ClipboardEntry Make(string text, int minute) => TestData.Entry(Identity, text, minute);

    // The node must trust this peer already (TestNode.Trust), or it is a pairing request.
    public async Task ConnectAsync(TestNode node, int protocol = HandshakeMessage.CurrentProtocol)
    {
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, node.Port);
        conn = await PeerConnection.CreateAsync(client, Identity, new TrustStore(label), new PassphraseKeyStore(label), "raw peer", protocol: protocol);
        Assert.NotNull(conn);
        conn!.MessageReceived += msg =>
        {
            lock (inbox) inbox.Add(JsonSerializer.Deserialize<Envelope>(msg)!);
        };
        _ = conn.Listen();
    }

    public int PeerProtocol => conn!.PeerProtocol;

    public Task SendAsync(string type, string payload) => conn!.Send(JsonSerializer.Serialize(new Envelope(type, payload)));

    public Task SendHeadAsync(IReadOnlyList<ClipboardEntry> history, params string[] deleted) =>
        SendAsync("history_head", JsonSerializer.Serialize(HistoryHead.ForSync(history, deleted)));

    public Task SendBatchAsync(params ClipboardEntry[] entries) => SendAsync("history_batch", JsonSerializer.Serialize(entries.ToList()));

    public void Close() => conn?.Close();

    // Everything of this type received so far, oldest first.
    public List<Envelope> Received(string type)
    {
        lock (inbox) { return inbox.Where(envelope => envelope.Type == type).ToList(); }
    }

    public async Task<List<Envelope>> WaitForAsync(string type, int count)
    {
        await Wait.Until(() => Received(type).Count >= count);
        return Received(type);
    }

    // The keys of a history_request or delete.
    public static List<string> KeysOf(Envelope envelope) => KeysMessage.Parse(envelope.Payload);

    public void Dispose()
    {
        conn?.Close();
        TestData.Delete(label);
    }
}
