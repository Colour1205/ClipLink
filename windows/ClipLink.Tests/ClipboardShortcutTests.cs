using System.Text.Json;
using Xunit;

namespace ClipLink.Tests;

public sealed class ClipboardShortcutTests
{
    [Fact]
    public void A_custom_shortcut_survives_settings_serialization()
    {
        var shortcut = new ClipboardShortcut(6, 0x72);
        var loaded = JsonSerializer.Deserialize<ClipboardShortcut>(JsonSerializer.Serialize(shortcut));

        Assert.Equal(shortcut, loaded);
        Assert.True(loaded.IsSupported());
        Assert.Equal("Ctrl+Shift+F3", loaded.ToString());
    }

    [Fact]
    public void The_default_stays_available_and_F12_cannot_be_selected()
    {
        Assert.True(ClipboardShortcut.Default.IsSupported());
        Assert.Equal("Ctrl+Alt+Shift+V", ClipboardShortcut.Default.ToString());
        Assert.False(new ClipboardShortcut(7, 0x7b).IsSupported());
    }
}
