using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.Tests;

// Whether a copy is one this device already has (the spec's 1.3), what
// ClipLink remembers having written (LastWrite), when a file whose bytes come
// late still goes on the clipboard (PendingApply), and store files written so
// a crash can't cut them off (SafeFile).
public class LastWriteTests
{
    private static readonly string A = ContentPrint.Text("A");
    private static readonly string B = ContentPrint.Text("B");
    private static readonly Func<string, bool> Nowhere = _ => false;

    private static Func<string, bool> In(params string[] prints) => prints.ToHashSet().Contains;

    // ---- classifying a copy ----

    [Fact]
    public void An_automatic_capture_of_ClipLinks_own_write_is_already_synced_even_after_a_delete()
    {
        Assert.True(LastWrite.IsAlready(manual: false, ownWrite: true, new[] { A }, captured: null, Nowhere, Nowhere));
    }

    [Fact]
    public void A_manual_capture_of_ClipLinks_own_write_is_already_synced_while_it_is_in_history()
    {
        Assert.True(LastWrite.IsAlready(manual: true, ownWrite: true, new[] { A }, new[] { A }, In(A), Nowhere));
    }

    [Fact]
    public void A_manual_capture_after_the_item_was_deleted_is_sent_again()
    {
        Assert.False(LastWrite.IsAlready(manual: true, ownWrite: true, new[] { A }, new[] { A }, Nowhere, Nowhere));
    }

    [Fact]
    public void A_copy_of_what_ClipLink_last_wrote_or_saw_is_already_synced()
    {
        Assert.True(LastWrite.IsAlready(manual: false, ownWrite: false, new[] { A }, new[] { A }, Nowhere, Nowhere));
    }

    [Fact]
    public void A_copy_of_the_newest_item_is_already_synced()
    {
        Assert.True(LastWrite.IsAlready(manual: false, ownWrite: false, new[] { B }, new[] { A }, In(A), In(A)));
    }

    [Fact]
    public void A_then_B_then_A_again_sends_A_again()
    {
        // A was copied and sent, then B: B is the newest item and what the clipboard held.
        Assert.False(LastWrite.IsAlready(manual: false, ownWrite: false, new[] { B }, new[] { A }, In(A, B), In(B)));
    }

    [Fact]
    public void A_file_selection_is_already_synced_only_when_every_file_is()
    {
        string f1 = ContentPrint.File(new string('a', 64)), f2 = ContentPrint.File(new string('b', 64));

        Assert.True(LastWrite.IsAlready(false, false, new[] { f1, f2 }, new[] { f2, f1 }, Nowhere, Nowhere, every: true));
        Assert.False(LastWrite.IsAlready(false, false, new[] { f1 }, new[] { f1, f2 }, Nowhere, Nowhere, every: true));
    }

    [Fact]
    public void A_read_that_failed_sends_nothing()
    {
        Assert.True(LastWrite.IsAlready(false, false, Array.Empty<string>(), captured: null, Nowhere, Nowhere));
    }

    // ---- the record ----

    [Fact]
    public void A_write_records_its_prints_and_the_sequence_number_after_it()
    {
        var record = new LastWrite();

        record.Wrote(new[] { A, null }, 42);

        Assert.True(record.Holds(A));
        Assert.False(record.Holds(B));
        Assert.False(record.Holds(null));
        Assert.True(record.IsOwnWrite(42));
        Assert.False(record.IsOwnWrite(43));
    }

    [Fact]
    public void A_copy_looked_at_replaces_the_prints_and_keeps_the_count()
    {
        var record = new LastWrite();
        record.Wrote(new[] { A }, 7);

        record.Classified(new[] { B });

        Assert.False(record.Holds(A));
        Assert.True(record.Holds(B));
        Assert.True(record.IsOwnWrite(7));
    }

    [Fact]
    public void Files_classified_after_ClipLink_wrote_meanwhile_leave_the_record_alone()
    {
        var record = new LastWrite();
        long since = record.Generation;
        record.Wrote(new[] { A }, 3); // a peer item applied while the files were hashed

        Assert.False(record.ClassifiedIfUnchanged(new[] { B }, since));
        Assert.True(record.Holds(A));
        Assert.True(record.ClassifiedIfUnchanged(new[] { B }, record.Generation));
        Assert.True(record.Holds(B));
    }

    // ---- a file whose bytes come later ----

    [Fact]
    public void A_pending_file_goes_on_the_clipboard_only_if_nothing_changed_it_and_within_ten_minutes()
    {
        var entry = new ClipboardEntry("{}", "file", "PEER", DateTime.UtcNow, "sig");
        var pending = new PendingApply(entry, ArmedAt: 1_000, Sequence: 5);

        Assert.True(pending.IsDue(1_000 + PendingApply.MaxWaitMs, 5));
        Assert.False(pending.IsDue(1_000 + PendingApply.MaxWaitMs + 1, 5));
        Assert.False(pending.IsDue(2_000, 6));
    }

    // ---- store files ----

    [Fact]
    public void A_store_file_is_read_back_from_its_backup_when_it_is_cut_off()
    {
        string dir = Path.Combine(Path.GetTempPath(), "cliplink-safefile-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            string path = Path.Combine(dir, "history.json");
            SafeFile.Write(path, "[1]");
            SafeFile.Write(path, "[1,2]");
            Assert.Equal("[1,2]", File.ReadAllText(path));
            Assert.Equal("[1]", File.ReadAllText(path + ".bak"));
            Assert.False(File.Exists(path + ".tmp"));

            File.WriteAllText(path, "[1,2"); // a crash midway, by an older build
            var read = SafeFile.Read(path, json => System.Text.Json.JsonSerializer.Deserialize<List<int>>(json)!, "test");

            Assert.Equal(new List<int> { 1 }, read);
            Assert.Equal("[1,2", File.ReadAllText(path + ".corrupt")); // kept, not overwritten
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void A_missing_store_file_reads_as_nothing()
    {
        string path = Path.Combine(Path.GetTempPath(), "cliplink-missing-" + Guid.NewGuid().ToString("N") + ".json");

        Assert.Null(SafeFile.Read(path, json => json, "test"));
    }
}
