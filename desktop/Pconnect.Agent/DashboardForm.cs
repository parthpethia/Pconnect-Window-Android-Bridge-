using Pconnect.Agent.Services;

namespace Pconnect.Agent;

internal sealed class DashboardForm : Form
{
    private readonly AgentRuntime _runtime;
    private readonly Label _serverValue;
    private readonly Label _deviceValue;
    private readonly Button _toggleServerButton;

    internal bool AllowClose { get; set; }

    public DashboardForm(AgentRuntime runtime)
    {
        _runtime = runtime;

        Text = "Pconnect Dashboard";
        Width = 520;
        Height = 240;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        BackColor = SystemColors.Window;

        var header = new Label
        {
            Text = "Pconnect",
            AutoSize = true,
            Font = new Font(Font, FontStyle.Bold),
            Left = 18,
            Top = 16,
        };

        var subtitle = new Label
        {
            Text = "Desktop agent status",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Left = 18,
            Top = 40,
        };

        var grid = new TableLayoutPanel
        {
            Left = 18,
            Top = 72,
            Width = ClientSize.Width - 36,
            Height = 80,
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            ColumnCount = 2,
            RowCount = 2,
            AutoSize = false,
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 160));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        var serverLabel = MakeKeyLabel("Server");
        _serverValue = MakeValueLabel();

        var deviceLabel = MakeKeyLabel("Connected device");
        _deviceValue = MakeValueLabel();

        grid.Controls.Add(serverLabel, 0, 0);
        grid.Controls.Add(_serverValue, 1, 0);
        grid.Controls.Add(deviceLabel, 0, 1);
        grid.Controls.Add(_deviceValue, 1, 1);

        _toggleServerButton = new Button
        {
            Left = 18,
            Top = 170,
            Width = 160,
            Height = 32,
            Anchor = AnchorStyles.Left | AnchorStyles.Bottom,
            UseVisualStyleBackColor = true,
        };
        _toggleServerButton.Click += async (_, _) => await ToggleServerAsync();

        var closeButton = new Button
        {
            Text = "Close",
            Left = 190,
            Top = 170,
            Width = 100,
            Height = 32,
            Anchor = AnchorStyles.Left | AnchorStyles.Bottom,
            UseVisualStyleBackColor = true,
        };
        closeButton.Click += (_, _) => Hide();

        var hint = new Label
        {
            Text = "Tip: Close hides the window; use tray icon to reopen.",
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Left = 18,
            Top = 206,
            Anchor = AnchorStyles.Left | AnchorStyles.Bottom,
        };

        Controls.Add(header);
        Controls.Add(subtitle);
        Controls.Add(grid);
        Controls.Add(_toggleServerButton);
        Controls.Add(closeButton);
        Controls.Add(hint);

        FormClosing += (_, e) =>
        {
            if (!AllowClose && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
            }
        };

        _runtime.StateChanged += (_, _) => PostUpdateUi();

        Shown += (_, _) => UpdateUi();
    }

    private static Label MakeKeyLabel(string text)
    {
        return new Label
        {
            Text = text,
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Padding = new Padding(0, 6, 0, 6),
            Anchor = AnchorStyles.Left,
        };
    }

    private static Label MakeValueLabel()
    {
        return new Label
        {
            AutoSize = true,
            Padding = new Padding(0, 6, 0, 6),
            Anchor = AnchorStyles.Left,
        };
    }

    private async Task ToggleServerAsync()
    {
        _toggleServerButton.Enabled = false;

        try
        {
            if (_runtime.IsServerRunning)
            {
                _toggleServerButton.Text = "Stopping…";
                await Task.Run(() => _runtime.StopServer());
            }
            else
            {
                _toggleServerButton.Text = "Starting…";
                await Task.Run(() => _runtime.StartServer());
            }
        }
        finally
        {
            _toggleServerButton.Enabled = true;
            UpdateUi();
        }
    }

    private void PostUpdateUi()
    {
        if (IsDisposed)
        {
            return;
        }

        try
        {
            BeginInvoke(UpdateUi);
        }
        catch
        {
            // ignore
        }
    }

    private void UpdateUi()
    {
        if (IsDisposed)
        {
            return;
        }

        _serverValue.Text = _runtime.IsServerRunning ? "Running" : "Stopped";
        _deviceValue.Text = _runtime.ConnectedDeviceDisplay;
        _toggleServerButton.Text = _runtime.IsServerRunning ? "Stop server" : "Start server";
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
    }
}
