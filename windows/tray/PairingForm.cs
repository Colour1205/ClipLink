using System.Text.Json;
using QRCoder;

namespace ClipboardTray;

// Replaces the old one-sided "Trust a Device" flow: trust is never written
// just because a key/QR was pasted or scanned anymore. This form being open
// IS "pairing mode" (sends set_pairing_mode on open/close, mirroring
// HarmonyOS's Index.ets pairingOpen) - a pairing handshake with a new
// device only completes at all while both sides have their own version of
// this window open, and even then only actually pairs once the user here
// taps Accept on a live, signature-verified request (polled from the
// daemon's PairingState - see get_pending_pairing_info/accept_pairing/
// reject_pairing in Program.cs). Scanning was never possible on Windows
// (no camera API used here) - "Pair by Address" is the equivalent entry
// point, taking either a bare address or the full pairing JSON another
// device's own pairing screen shows/copies.
public class PairingForm : Form
{
    private readonly IpcClient ipcClient;
    private readonly System.Windows.Forms.Timer pollTimer;
    private readonly TextBox addressInput;
    private readonly Button pairButton;
    private readonly Label pendingLabel;
    private readonly Button acceptButton;
    private readonly Button rejectButton;
    private readonly TextBox myInfoBox;
    private readonly PictureBox qrPictureBox;
    // The prompt text currently shown, not just the peer id - so a name that
    // only turns up a poll later (from the peer's beacon) still updates it.
    private string? lastPromptText;
    // Same guard as ManageDevicesForm's - stops overlapping polls from
    // piling up if the daemon is slow or unreachable for a stretch.
    private bool isPolling = false;

    public PairingForm(IpcClient ipcClient)
    {
        this.ipcClient = ipcClient;

        Text = "Pairing";
        Icon = AppIcon.Window;
        Width = 460;
        Height = 820;
        StartPosition = FormStartPosition.CenterScreen;

        var explainerLabel = new Label
        {
            Text = "This window open = pairable. A request only reaches this device while this is open, and only completes once you tap Accept below - keep it open on BOTH devices at the same time while pairing.",
            Dock = DockStyle.Top,
            Height = 60,
            AutoEllipsis = false
        };

        // Same QR this device's Pairing screen would scan on a phone - kept
        // in the SAME window as accept/reject and Pair by Address, not a
        // separate "Show My QR Code" dialog, since showing the code was
        // never actually "pairing" by itself - only this window being open
        // is (see set_pairing_mode below).
        qrPictureBox = new PictureBox
        {
            SizeMode = PictureBoxSizeMode.Zoom,
            Dock = DockStyle.Top,
            Height = 260
        };

        var myInfoLabel = new Label
        {
            Text = "This device's pairing info (copy and send to the other device):",
            Dock = DockStyle.Top,
            Height = 20
        };
        myInfoBox = new TextBox
        {
            ReadOnly = true,
            Dock = DockStyle.Top,
            Height = 50,
            Multiline = true,
            ScrollBars = ScrollBars.Vertical
        };

        var pairLabel = new Label
        {
            Text = "Pair by address (paste the other device's address or pairing info):",
            Dock = DockStyle.Top,
            Height = 20
        };
        addressInput = new TextBox { Dock = DockStyle.Top };
        pairButton = new Button { Text = "Pair by Address", Dock = DockStyle.Top, Height = 32 };
        pairButton.Click += async (s, e) => await OnPairByAddress();

        pendingLabel = new Label
        {
            Text = "",
            Dock = DockStyle.Top,
            Height = 56, // room for a long device name to wrap
            UseMnemonic = false, // a '&' in a device name is just a '&'
            Visible = false
        };
        acceptButton = new Button { Text = "Accept", Dock = DockStyle.Left, Width = 100, Visible = false };
        acceptButton.Click += async (s, e) => await OnAccept();
        rejectButton = new Button { Text = "Reject", Dock = DockStyle.Right, Width = 100, Visible = false };
        rejectButton.Click += async (s, e) => await OnReject();
        var pendingButtonsPanel = new Panel { Dock = DockStyle.Top, Height = 40 };
        pendingButtonsPanel.Controls.Add(acceptButton);
        pendingButtonsPanel.Controls.Add(rejectButton);

        // Added in reverse order — DockStyle.Top stacks each newly-added
        // control above the previous ones.
        Controls.Add(pendingButtonsPanel);
        Controls.Add(pendingLabel);
        Controls.Add(pairButton);
        Controls.Add(addressInput);
        Controls.Add(pairLabel);
        Controls.Add(myInfoBox);
        Controls.Add(myInfoLabel);
        Controls.Add(qrPictureBox);
        Controls.Add(explainerLabel);

        pollTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        pollTimer.Tick += async (s, e) => await PollPending();

        Load += async (s, e) => await OnLoad();
        FormClosed += (s, e) => OnClosed();
    }

    private async Task OnLoad()
    {
        await ipcClient.Send(new IpcRequest("set_pairing_mode", "1"));

        var response = await ipcClient.Send(new IpcRequest("get_pairing_info"));
        string payload = response?.Success == true ? response.Data ?? "" : "";
        myInfoBox.Text = payload.Length > 0 ? payload : "Could not reach the daemon.";

        if (payload.Length > 0)
        {
            using var qrGenerator = new QRCodeGenerator();
            using var qrCodeData = qrGenerator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
            using var qrCode = new QRCode(qrCodeData);
            qrPictureBox.Image = qrCode.GetGraphic(8);
        }

        pollTimer.Start();
    }

    private void OnClosed()
    {
        pollTimer.Stop();
        // Fire-and-forget — the form is closing, nothing left to await into.
        _ = ipcClient.Send(new IpcRequest("set_pairing_mode", "0"));
    }

    private async Task OnPairByAddress()
    {
        string address = addressInput.Text.Trim();
        if (address.Length == 0)
        {
            MessageBox.Show("Enter an address first.", "Pairing");
            return;
        }
        pairButton.Enabled = false;
        pairButton.Text = "Connecting...";
        try
        {
            var response = await ipcClient.Send(new IpcRequest("pair_by_address", address));
            if (response == null || !response.Success)
            {
                MessageBox.Show("Could not reach the daemon. Is it running?", "Pairing");
            }
        }
        finally
        {
            pairButton.Enabled = true;
            pairButton.Text = "Pair by Address";
        }
    }

    private async Task PollPending()
    {
        if (isPolling) return;
        isPolling = true;
        try
        {
            await PollPendingCore();
        }
        finally
        {
            isPolling = false;
        }
    }

    private async Task PollPendingCore()
    {
        var pending = await FetchPending();

        if (pending == null || string.IsNullOrEmpty(pending.PublicKey))
        {
            lastPromptText = null;
            pendingLabel.Visible = false;
            acceptButton.Visible = false;
            rejectButton.Visible = false;
            return;
        }

        string from = DeviceLabel.Of(pending.PublicKey, pending.Name);
        if (!string.IsNullOrEmpty(pending.Address)) from += $" ({pending.Address})";
        string promptText = $"Pairing request from: {from}\nOnly accept if you expect this.";
        if (promptText == lastPromptText) return; // already showing this one
        lastPromptText = promptText;
        pendingLabel.Text = promptText;
        pendingLabel.Visible = true;
        acceptButton.Visible = true;
        rejectButton.Visible = true;
    }

    // The pending request with its name, or null when nothing is pending. A
    // daemon still running from before device names doesn't know
    // get_pending_pairing_info - fall back to its bare-id get_pending_pairing
    // rather than never showing the request at all.
    private async Task<PendingPairingInfo?> FetchPending()
    {
        var response = await ipcClient.Send(new IpcRequest("get_pending_pairing_info"));
        if (response is { Success: false })
        {
            var legacy = await ipcClient.Send(new IpcRequest("get_pending_pairing"));
            string peerId = legacy?.Success == true ? (legacy.Data ?? "") : "";
            return peerId.Length > 0 ? new PendingPairingInfo(peerId, null, null) : null;
        }

        string json = response?.Success == true ? (response.Data ?? "") : "";
        if (json.Length == 0) return null;
        try { return JsonSerializer.Deserialize<PendingPairingInfo>(json); }
        catch (JsonException) { return null; } // treated as nothing pending
    }

    private async Task OnAccept()
    {
        acceptButton.Enabled = false;
        rejectButton.Enabled = false;
        try
        {
            await ipcClient.Send(new IpcRequest("accept_pairing"));
        }
        finally
        {
            lastPromptText = null;
            pendingLabel.Visible = false;
            acceptButton.Visible = false;
            rejectButton.Visible = false;
            acceptButton.Enabled = true;
            rejectButton.Enabled = true;
        }
    }

    private async Task OnReject()
    {
        acceptButton.Enabled = false;
        rejectButton.Enabled = false;
        try
        {
            await ipcClient.Send(new IpcRequest("reject_pairing"));
        }
        finally
        {
            lastPromptText = null;
            pendingLabel.Visible = false;
            acceptButton.Visible = false;
            rejectButton.Visible = false;
            acceptButton.Enabled = true;
            rejectButton.Enabled = true;
        }
    }
}
