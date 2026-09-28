using System.Text.Json;

namespace ClipboardTray;

// Lists every trusted device (then any untrusted one currently beaconing on
// the LAN) by name with the addresses it's reachable at, marks which ones
// are currently connected, and lets you untrust one — the missing "revoke"
// side of pairing. Hover a row for its full device id.
public class ManageDevicesForm : Form
{
    private readonly IpcClient ipcClient;
    private readonly ListView listView;
    private readonly Label statusLabel;
    private readonly Button untrustButton;
    private readonly System.Windows.Forms.Timer pollTimer;
    // Guards against overlapping polls - without it, a Tick firing while a
    // previous RefreshDevices() is still awaiting (e.g. the daemon isn't
    // responding) stacks up more and more concurrent calls, each shown to
    // the user - that's what caused a cascade of "Could not reach the
    // daemon" dialogs when the daemon was stopped.
    private bool isRefreshing = false;

    public ManageDevicesForm(IpcClient ipcClient)
    {
        this.ipcClient = ipcClient;
        Text = "Manage Devices";
        Icon = AppIcon.Window;
        Width = 640;
        Height = 400;
        StartPosition = FormStartPosition.CenterScreen;

        statusLabel = new Label
        {
            Text = "",
            Dock = DockStyle.Top,
            Height = 24,
            ForeColor = System.Drawing.Color.Firebrick,
            Visible = false
        };

        listView = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            MultiSelect = false,
            ShowItemToolTips = true
        };
        listView.Columns.Add("Device", 200);
        listView.Columns.Add("Addresses", 230);
        listView.Columns.Add("Status", 170);

        untrustButton = new Button
        {
            Text = "Untrust Selected",
            Dock = DockStyle.Bottom,
            Height = 32
        };
        untrustButton.Click += async (s, e) =>
        {
            if (SelectedDevice() is not { Trusted: true } device) return;
            await ipcClient.Send(new IpcRequest("untrust_device", device.PublicKey));
            await RefreshDevices();
        };
        // Only a trusted device can be untrusted - a discovered one has
        // nothing to revoke.
        listView.SelectedIndexChanged += (s, e) => untrustButton.Enabled = SelectedDevice()?.Trusted != false;

        Controls.Add(listView);
        Controls.Add(statusLabel);
        Controls.Add(untrustButton);

        // Previously only refreshed once on Load - the Connected/Not
        // connected column never moved again after that, no matter what
        // actually happened, since nothing re-queried the daemon. Polling
        // while this window is open is the same low-effort fix
        // PairingForm's pending-request check already uses.
        pollTimer = new System.Windows.Forms.Timer { Interval = 1500 };
        pollTimer.Tick += async (s, e) => await RefreshDevices();
        FormClosed += (s, e) => pollTimer.Stop();

        Load += async (s, e) => { await RefreshDevices(); pollTimer.Start(); };
    }

    private DeviceListing? SelectedDevice() =>
        listView.SelectedItems.Count > 0 ? listView.SelectedItems[0].Tag as DeviceListing : null;

    // The daemon's list_devices order is stable - never by connection state
    // or last-seen time - so a poll usually returns the same devices in the
    // same order, and those rows are just updated in place: rebuilding them
    // every 1.5s would reset the scroll position and close the hover tooltip
    // (the only place the full device id shows). Only when a device comes or
    // goes, or a name changes its place, is the list rebuilt, re-selecting
    // the previously selected device afterwards.
    private async Task RefreshDevices()
    {
        if (isRefreshing) return; // previous poll still in flight - don't pile another on top
        isRefreshing = true;
        try
        {
            await RefreshDevicesCore();
        }
        finally
        {
            isRefreshing = false;
        }
    }

    private async Task RefreshDevicesCore()
    {
        var response = await ipcClient.Send(new IpcRequest("list_devices"));

        if (response == null || !response.Success)
        {
            // Inline status text, not a MessageBox - this runs on every poll
            // tick while the daemon is unreachable, and a modal dialog per
            // tick is exactly what caused the earlier cascade. The list
            // itself is left as-is (not cleared) so a transient hiccup
            // doesn't blank it out.
            statusLabel.Text = response == null
                ? "Could not reach the daemon - is it running?"
                : "The daemon is out of date - restart it.";
            statusLabel.Visible = true;
            return;
        }
        statusLabel.Visible = false;

        var devices = response.Data != null
            ? JsonSerializer.Deserialize<List<DeviceListing>>(response.Data) ?? new()
            : new List<DeviceListing>();

        bool sameRows = listView.Items.Count == devices.Count
            && devices.Select((device, i) => (listView.Items[i].Tag as DeviceListing)?.PublicKey == device.PublicKey).All(same => same);
        if (sameRows)
        {
            for (int i = 0; i < devices.Count; i++)
            {
                FillRow(listView.Items[i], devices[i]);
            }
        }
        else
        {
            string? selectedKey = SelectedDevice()?.PublicKey;
            listView.BeginUpdate();
            try
            {
                listView.Items.Clear();
                foreach (var device in devices)
                {
                    var item = new ListViewItem { ToolTipText = device.PublicKey };
                    item.SubItems.Add("");
                    item.SubItems.Add("");
                    FillRow(item, device);
                    listView.Items.Add(item);
                    if (device.PublicKey == selectedKey)
                    {
                        item.Selected = true;
                        item.Focused = true;
                    }
                }
            }
            finally
            {
                listView.EndUpdate();
            }
        }
        // Also when the selected row just went away (no selection event
        // is guaranteed for that).
        untrustButton.Enabled = SelectedDevice()?.Trusted != false;
    }

    // Only assigns text that actually changed - an unchanged poll then
    // doesn't touch the native control at all.
    private static void FillRow(ListViewItem item, DeviceListing device)
    {
        SetText(item.SubItems[0], DeviceLabel.Of(device.PublicKey, device.Name));
        SetText(item.SubItems[1], string.Join(" · ", device.Addresses ?? new List<string>()));
        SetText(item.SubItems[2], StatusText(device));
        item.Tag = device;
    }

    private static void SetText(ListViewItem.ListViewSubItem subItem, string text)
    {
        if (subItem.Text != text) subItem.Text = text;
    }

    private static string StatusText(DeviceListing device)
    {
        if (device.Trusted) return device.Connected ? "Connected" : "Not connected";
        return device.PairingOpen ? "Discovered - pairing open" : "Discovered";
    }
}
