using System.Diagnostics;

namespace ClipboardDaemon.Networking;

// Reads this device's own Tailscale IP by shelling out to the Tailscale CLI.
// Deliberately never asks Tailscale for the whole tailnet's peer list — only
// "what's my own address" — since that's the one piece every platform this
// project targets (including mobile, eventually) can realistically answer,
// unlike enumerating peers, which isn't available to arbitrary apps.
public static class TailscaleHelper
{
    public static string? GetOwnTailscaleIp()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "tailscale",
                Arguments = "ip -4",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var process = Process.Start(psi);
            if (process == null) return null;

            string output = process.StandardOutput.ReadToEnd().Trim();
            process.WaitForExit(3000);

            return string.IsNullOrWhiteSpace(output) ? null : output;
        }
        catch (Exception)
        {
            // Tailscale not installed, not running, or not on PATH — not fatal,
            // this device just won't have an off-LAN address to offer at pairing time.
            return null;
        }
    }
}
