namespace ClipLink;

internal readonly record struct ClipboardShortcut(uint Modifiers, uint Key)
{
    // RegisterHotKey uses these values for Alt (1), Ctrl (2) and Shift (4).
    internal static IReadOnlyList<(uint Value, string Label)> ModifierOptions { get; } =
    [
        (3, "Ctrl+Alt"),
        (6, "Ctrl+Shift"),
        (5, "Alt+Shift"),
        (7, "Ctrl+Alt+Shift"),
    ];

    internal static IReadOnlyList<uint> KeyOptions { get; } =
        Enumerable.Range('A', 26).Concat(Enumerable.Range('0', 10)).Concat(Enumerable.Range(0x70, 11))
            .Select(key => (uint)key).ToArray();

    internal static ClipboardShortcut Default => new(7, 'V');

    internal bool IsSupported() => ModifierLabel() != null && KeyOptions.Contains(Key);

    internal static string KeyLabel(uint key) => key >= 0x70 ? $"F{key - 0x6f}" : ((char)key).ToString();

    private string? ModifierLabel()
    {
        foreach (var option in ModifierOptions)
        {
            if (option.Value == Modifiers) return option.Label;
        }
        return null;
    }

    public override string ToString() => $"{ModifierLabel()}+{KeyLabel(Key)}";
}
