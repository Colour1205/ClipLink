using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Identity;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.EngineTests;

// The stores on disk and the bytes that are signed, after the changes that
// make them cheaper or crash-safe: the same bytes and files as before, read
// the same by older builds. Each test has labels of its own (TestData), so
// these don't share the engine log.
public class StoreTests
{
    private static string PathOf(string file) => Path.Combine(TestData.Dir, file);

    // ---- what is signed ----

    [Theory]
    [InlineData("plain text")]
    [InlineData("中文剪贴板 and 🙂 emoji")]
    [InlineData("")]
    [InlineData("ends in half a pair \uD83D")]
    [InlineData("\uDE42 starts with the other half")]
    [InlineData("a:b:c, colons")]
    public void The_signed_bytes_are_the_utf8_of_the_joined_string_every_platform_signs(string content)
    {
        var entry = new ClipboardEntry(content, "text", "DEVICE+/=", new DateTime(2026, 10, 1, 12, 0, 0, DateTimeKind.Utc));

        byte[] made = new SigningService().getSignableData(entry);

        byte[] joined = Encoding.UTF8.GetBytes($"{entry.Content}:{entry.Type}:{entry.DeviceId}:{entry.Timestamp.ToString("o")}");
        Assert.Equal(joined, made);
    }

    [Fact]
    public void An_entry_signed_here_still_verifies()
    {
        string label = TestData.NewLabel("sign");
        try
        {
            var identity = new DeviceIdentity(label);
            var entry = SigningService.Sign(new ClipboardEntry("中文 🙂 " + new string('x', 5000), "text", identity.GetPublicKey(), DateTime.UtcNow), identity);

            Assert.True(SigningService.Verify(entry, identity.GetPublicKey()));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    // ---- the identity key ----

    [Fact]
    public void The_identity_key_is_the_same_at_the_next_start()
    {
        string label = TestData.NewLabel("id");
        try
        {
            string first = new DeviceIdentity(label).GetPublicKey();

            Assert.Equal(first, new DeviceIdentity(label).GetPublicKey());
            Assert.False(File.Exists(PathOf($"identity{label}.key.tmp")));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public void A_corrupt_identity_key_is_replaced_and_kept_aside()
    {
        string label = TestData.NewLabel("idbad");
        try
        {
            string first = new DeviceIdentity(label).GetPublicKey();
            File.WriteAllBytes(PathOf($"identity{label}.key"), new byte[] { 1, 2, 3 });

            string second = new DeviceIdentity(label).GetPublicKey();

            Assert.NotEqual(first, second);
            Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(PathOf($"identity{label}.key.bad")));
            Assert.Equal(second, new DeviceIdentity(label).GetPublicKey());
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public void An_identity_key_held_by_another_program_stops_the_start_and_is_left_alone()
    {
        string label = TestData.NewLabel("idlock");
        try
        {
            new DeviceIdentity(label);
            string path = PathOf($"identity{label}.key");
            byte[] before = File.ReadAllBytes(path);

            using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                Assert.ThrowsAny<IOException>(() => new DeviceIdentity(label));
            }

            Assert.Equal(before, File.ReadAllBytes(path));
            Assert.False(File.Exists(path + ".bad"));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    // ---- the trust store ----

    [Fact]
    public void A_trust_store_cut_off_midway_comes_back_from_its_backup()
    {
        string label = TestData.NewLabel("trust");
        try
        {
            var store = new TrustStore(label);
            store.Trust("PHONE-A", null, "Phone A");
            store.Trust("PHONE-B", null, "Phone B"); // the second save keeps the first as .bak
            string path = PathOf($"truststore{label}.json");
            File.WriteAllText(path, File.ReadAllText(path)[..10]);

            var reloaded = new TrustStore(label);

            Assert.True(reloaded.IsTrusted("PHONE-A"));
            Assert.True(File.Exists(path + ".corrupt"));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public void A_trust_store_held_by_another_program_stops_the_start_instead_of_starting_empty()
    {
        string label = TestData.NewLabel("trustlock");
        try
        {
            new TrustStore(label).Trust("PHONE-A", null, "Phone A");
            string path = PathOf($"truststore{label}.json");

            using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                Assert.ThrowsAny<IOException>(() => new TrustStore(label));
            }

            Assert.True(new TrustStore(label).IsTrusted("PHONE-A"));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    // ---- history ----

    [Fact]
    public void History_is_written_in_the_background_and_read_back_whole_as_any_build_reads_it()
    {
        string label = TestData.NewLabel("hist");
        try
        {
            var identity = new DeviceIdentity(label);
            var fileStore = new FileStore(label);
            var history = new HistoryAccess(label, fileStore, new DeletedEntries(label));
            var picture = Convert.ToBase64String(RandomNumberGenerator.GetBytes(300_000));
            var entries = new[]
            {
                TestData.Entry(identity, "中文剪贴板 \"quoted\" 🙂", 1),
                SigningService.Sign(new ClipboardEntry(picture, "image", identity.GetPublicKey(), TestData.Base.AddMinutes(2)), identity),
                TestData.Entry(identity, "three", 3),
            };
            foreach (var entry in entries) Assert.True(history.addToHistory(entry));

            history.Flush();

            string path = PathOf($"history{label}.json");
            // What an older build does: the whole file as text, the default options.
            var asOldBuildsReadIt = JsonSerializer.Deserialize<List<ClipboardEntry>>(File.ReadAllText(path))!;
            Assert.Equal(entries.OrderBy(e => e.Timestamp), asOldBuildsReadIt.OrderBy(e => e.Timestamp));
            Assert.Equal(entries.OrderBy(e => e.Timestamp), new HistoryAccess(label, fileStore, new DeletedEntries(label)).GetHistory().OrderBy(e => e.Timestamp));
            Assert.False(File.Exists(path + ".tmp"));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public void Many_changes_in_a_row_end_with_the_newest_on_disk()
    {
        string label = TestData.NewLabel("histmany");
        try
        {
            var identity = new DeviceIdentity(label);
            var fileStore = new FileStore(label);
            var history = new HistoryAccess(label, fileStore, new DeletedEntries(label));
            for (int i = 1; i <= 40; i++) history.addToHistory(TestData.Entry(identity, $"item {i}", i));

            history.Flush();

            var reloaded = new HistoryAccess(label, fileStore, new DeletedEntries(label)).GetHistory();
            Assert.Equal(HistoryAccess.MaxHistoryItems, reloaded.Count);
            Assert.Contains(reloaded, e => e.Content == "item 40");
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public void History_or_deleted_items_held_by_another_program_stop_the_start_instead_of_starting_empty()
    {
        string label = TestData.NewLabel("histlock");
        try
        {
            var identity = new DeviceIdentity(label);
            var fileStore = new FileStore(label);
            var deleted = new DeletedEntries(label);
            var history = new HistoryAccess(label, fileStore, deleted);
            history.addToHistory(TestData.Entry(identity, "kept", 1));
            history.addToHistory(TestData.Entry(identity, "gone", 2));
            string goneKey = history.GetHistory().Single(e => e.Content == "gone").Key();
            history.removeFromHistory(goneKey);
            history.Flush();

            // Started empty, the next save would have written over them for good.
            using (new FileStream(PathOf($"history{label}.json"), FileMode.Open, FileAccess.Read, FileShare.None))
            {
                Assert.ThrowsAny<IOException>(() => new HistoryAccess(label, fileStore, new DeletedEntries(label)));
            }
            using (new FileStream(PathOf($"deleted{label}.json"), FileMode.Open, FileAccess.Read, FileShare.None))
            {
                Assert.ThrowsAny<IOException>(() => new DeletedEntries(label));
            }

            var reloaded = new HistoryAccess(label, fileStore, new DeletedEntries(label));
            Assert.Equal(new[] { "kept" }, reloaded.GetHistory().Select(e => e.Content));
            Assert.True(new DeletedEntries(label).Contains(goneKey));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    // ---- receiving a file ----

    [Fact]
    public void A_file_received_in_chunks_is_checked_as_it_arrives_and_stored()
    {
        string label = TestData.NewLabel("chunks");
        try
        {
            var fileStore = new FileStore(label);
            var incoming = new IncomingFiles(fileStore);
            byte[] data = RandomNumberGenerator.GetBytes(700_000);
            string hash = Convert.ToHexString(SHA256.HashData(data));
            var owner = new object();

            var results = data.Chunk(256 * 1024).Select((bytes, index) =>
                incoming.Receive(owner, new FileChunkMessage(hash, index, index == 2, ""), bytes)).ToList();

            Assert.Equal(new[] { IncomingFiles.Outcome.Written, IncomingFiles.Outcome.Written, IncomingFiles.Outcome.Stored }, results.Select(r => r.Outcome));
            Assert.Equal(data, File.ReadAllBytes(fileStore.GetPath(hash)));
        }
        finally
        {
            TestData.Delete(label);
        }
    }

    [Fact]
    public void A_file_whose_bytes_do_not_match_its_hash_is_not_stored()
    {
        string label = TestData.NewLabel("chunkbad");
        try
        {
            var fileStore = new FileStore(label);
            var incoming = new IncomingFiles(fileStore);
            byte[] data = RandomNumberGenerator.GetBytes(1000);
            string hash = Convert.ToHexString(SHA256.HashData(data));
            data[500] ^= 1;
            var owner = new object();

            var result = incoming.Receive(owner, new FileChunkMessage(hash, 0, true, ""), data);

            Assert.Equal(IncomingFiles.Outcome.Failed, result.Outcome);
            Assert.False(fileStore.Exists(hash));
            Assert.False(File.Exists(fileStore.GetTempPath(hash)));
        }
        finally
        {
            TestData.Delete(label);
        }
    }
}
