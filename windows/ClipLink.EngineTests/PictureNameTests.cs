using System.Text.Json;
using ClipboardDaemon.Clipboard;
using ClipboardDaemon.Crypto;
using ClipboardDaemon.Networking;
using ClipboardDaemon.Storage;
using Xunit;

namespace ClipLink.EngineTests;

// A picture's original name (the optional, unsigned "Name" of an "image"
// entry) with the real engine: sent with a copied picture, kept in history
// across a restart, served again in history batches, cleaned when it comes
// from another device, and never part of the signature or the key.
[Collection("engine log")]
public class PictureNameTests
{
    private static readonly byte[] Png = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7, 7 };

    public PictureNameTests() => LogTap.Start();

    private static ClipboardEntry Read(Envelope envelope) => JsonSerializer.Deserialize<ClipboardEntry>(envelope.Payload)!;

    [Fact]
    public async Task A_copied_picture_goes_out_with_its_name_and_the_signature_does_not_cover_it()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.WaitForAsync("history_head", 1);

        ClipboardSync.ByLabel[node.Label].CopyImage(Png, "after-like");

        var entry = Read(Assert.Single(await peer.WaitForAsync("entry", 1)));
        Assert.Equal(("image", "after-like"), (entry.Type, entry.Name));
        Assert.True(SigningService.Verify(entry, node.Id));
        // Signed exactly what an entry without the name signs.
        Assert.Equal(new SigningService().getSignableData(entry with { Name = null }), new SigningService().getSignableData(entry));
        Assert.True(SigningService.Verify(entry with { Name = "anything else" }, node.Id));
        Assert.True(SigningService.Verify(entry with { Name = null }, node.Id));
        Assert.Equal(entry.Signature, entry.Key());
    }

    [Fact]
    public async Task A_screenshot_goes_out_without_the_field_at_all()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.WaitForAsync("history_head", 1);

        ClipboardSync.ByLabel[node.Label].CopyImage(Png, null);

        var envelope = Assert.Single(await peer.WaitForAsync("entry", 1));
        Assert.DoesNotContain("\"Name\"", envelope.Payload);
        Assert.Null(Read(envelope).Name);
    }

    [Fact]
    public async Task The_name_is_kept_across_a_restart_and_served_in_a_history_batch()
    {
        using var node = new TestNode("a");
        node.Start();
        ClipboardSync.ByLabel[node.Label].CopyImage(Png, "after-like");
        Assert.True(await Wait.Until(() => node.Engine!.GetHistory().Count == 1));
        string key = node.Engine!.GetHistory()[0].Key;

        node.Start();   // stops the engine (history saved) and starts a new one, which loads it
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(new List<string> { key })));

        var batch = JsonSerializer.Deserialize<List<ClipboardEntry>>(Assert.Single(await peer.WaitForAsync("history_batch", 1)).Payload)!;
        var served = Assert.Single(batch);
        Assert.Equal((key, "after-like"), (served.Key(), served.Name));
        Assert.True(SigningService.Verify(served, node.Id));
    }

    [Fact]
    public async Task A_name_from_another_device_is_cleaned_kept_and_relayed_and_a_copy_without_it_is_no_new_entry()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.WaitForAsync("history_head", 1);
        var signed = SigningService.Sign(new ClipboardEntry(Convert.ToBase64String(Png), "image", peer.Id, TestData.Base.AddMinutes(1)), peer.Identity);

        // Written by hand, as a peer that does not clean its names might.
        string json = JsonSerializer.Serialize(signed, Wire.Json).TrimEnd('}') + ",\"Name\":\"..\\\\..\\\\Startup\\\\evil\\u0000.exe\"}";
        await peer.SendAsync("entry", json);
        Assert.True(await Wait.Until(() => node.Has(signed)));

        // The same entry again without its name (relayed by a build that drops it): still one entry.
        await peer.SendBatchAsync(signed);
        await Wait.Quiet();
        Assert.Single(node.Engine!.GetHistory());

        // A second device asks for it: it gets the cleaned name.
        using var other = new RawPeer("q");
        node.Trust(other.Id);
        await other.ConnectAsync(node);
        await other.SendAsync("history_request", JsonSerializer.Serialize(new KeysMessage(new List<string> { signed.Key() })));
        var served = Assert.Single(JsonSerializer.Deserialize<List<ClipboardEntry>>(Assert.Single(await other.WaitForAsync("history_batch", 1)).Payload)!);
        Assert.Equal("evil.exe", served.Name);
        Assert.Equal(signed.Signature, served.Signature);
        Assert.True(SigningService.Verify(served, peer.Id));
    }

    [Fact]
    public async Task An_entry_whose_name_is_not_text_is_still_taken()
    {
        using var node = new TestNode("a");
        node.Start();
        using var peer = new RawPeer("p");
        node.Trust(peer.Id);
        await peer.ConnectAsync(node);
        await peer.WaitForAsync("history_head", 1);
        var signed = SigningService.Sign(new ClipboardEntry(Convert.ToBase64String(Png), "image", peer.Id, TestData.Base.AddMinutes(1)), peer.Identity);

        string json = JsonSerializer.Serialize(signed, Wire.Json).TrimEnd('}') + ",\"Name\":{\"nested\":[1,2,3]}}";
        await peer.SendAsync("entry", json);

        Assert.True(await Wait.Until(() => node.Has(signed)));
    }
}
