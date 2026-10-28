using System.Globalization;

namespace ClipLink.Updates;

// A version as a release tag or App.Version writes it: "2.0.1", "v2.0", and
// optionally a pre-release part ("2.1.0-rc.1") and build metadata ("+abc123",
// ignored). Up to four numbers; "2.0" and "2.0.0" are the same version. A
// pre-release comes before the release it leads up to. Anything else
// ("latest", "2.x", "") doesn't parse.
internal readonly struct ReleaseVersion : IComparable<ReleaseVersion>, IEquatable<ReleaseVersion>
{
    private readonly string? text;

    private ReleaseVersion(int major, int minor, int patch, int revision, string? preRelease, string text)
    {
        Major = major;
        Minor = minor;
        Patch = patch;
        Revision = revision;
        PreRelease = preRelease;
        this.text = text;
    }

    public int Major { get; }
    public int Minor { get; }
    public int Patch { get; }
    public int Revision { get; }
    public string? PreRelease { get; }

    public bool IsPreRelease => PreRelease != null;

    // As written, without the "v" and the build metadata: only digits and
    // dots, plus "-<pre-release>" - safe to put in a file name or an address.
    public string Text => text ?? "0";

    public override string ToString() => Text;

    public static bool TryParse(string? value, out ReleaseVersion version)
    {
        version = default;
        if (value == null) return false;
        value = value.Trim();
        if (value.Length > 0 && value[0] is 'v' or 'V') value = value[1..];
        int metadata = value.IndexOf('+');
        if (metadata >= 0) value = value[..metadata];

        string? preRelease = null;
        int dash = value.IndexOf('-');
        if (dash >= 0)
        {
            preRelease = value[(dash + 1)..];
            value = value[..dash];
            if (!IsPreReleaseText(preRelease)) return false;
        }

        string[] parts = value.Split('.');
        if (parts.Length > 4) return false;
        var numbers = new int[4];
        for (int i = 0; i < parts.Length; i++)
        {
            if (!IsNumber(parts[i])) return false;
            numbers[i] = int.Parse(parts[i], CultureInfo.InvariantCulture);
        }

        string canonical = string.Join('.', numbers[..parts.Length]) + (preRelease != null ? "-" + preRelease : "");
        version = new ReleaseVersion(numbers[0], numbers[1], numbers[2], numbers[3], preRelease, canonical);
        return true;
    }

    // ASCII digits only (char.IsDigit takes other scripts' too), few enough
    // to fit an int.
    private static bool IsNumber(string part)
    {
        if (part.Length is 0 or > 9) return false;
        foreach (char c in part)
        {
            if (c is < '0' or > '9') return false;
        }
        return true;
    }

    // Dot-separated identifiers of letters, digits and '-'.
    private static bool IsPreReleaseText(string part)
    {
        if (part.Length == 0 || part.Length > 64) return false;
        foreach (string identifier in part.Split('.'))
        {
            if (identifier.Length == 0) return false;
            foreach (char c in identifier)
            {
                if (!(c is >= '0' and <= '9' or >= 'a' and <= 'z' or >= 'A' and <= 'Z' or '-')) return false;
            }
        }
        return true;
    }

    public int CompareTo(ReleaseVersion other)
    {
        int result = Major.CompareTo(other.Major);
        if (result == 0) result = Minor.CompareTo(other.Minor);
        if (result == 0) result = Patch.CompareTo(other.Patch);
        if (result == 0) result = Revision.CompareTo(other.Revision);
        if (result != 0) return result;
        if (PreRelease == null || other.PreRelease == null)
            return (PreRelease == null ? 1 : 0) - (other.PreRelease == null ? 1 : 0);
        return ComparePreRelease(PreRelease, other.PreRelease);
    }

    // As semver orders them: identifier by identifier, numbers as numbers and
    // before names, and a shorter list before a longer one that starts the same.
    private static int ComparePreRelease(string a, string b)
    {
        string[] left = a.Split('.');
        string[] right = b.Split('.');
        for (int i = 0; i < Math.Min(left.Length, right.Length); i++)
        {
            bool leftIsNumber = left[i].All(char.IsAsciiDigit);
            bool rightIsNumber = right[i].All(char.IsAsciiDigit);
            int result;
            if (leftIsNumber && rightIsNumber)
            {
                string l = left[i].TrimStart('0');
                string r = right[i].TrimStart('0');
                result = l.Length != r.Length ? l.Length.CompareTo(r.Length) : string.CompareOrdinal(l, r);
            }
            else if (leftIsNumber != rightIsNumber)
            {
                result = leftIsNumber ? -1 : 1;
            }
            else
            {
                result = string.CompareOrdinal(left[i], right[i]);
            }
            if (result != 0) return Math.Sign(result);
        }
        return left.Length.CompareTo(right.Length);
    }

    public bool Equals(ReleaseVersion other) => CompareTo(other) == 0;
    public override bool Equals(object? obj) => obj is ReleaseVersion other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(Major, Minor, Patch, Revision, PreRelease != null);

    public static bool operator ==(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) == 0;
    public static bool operator !=(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) != 0;
    public static bool operator <(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(ReleaseVersion a, ReleaseVersion b) => a.CompareTo(b) >= 0;
}
