using Pconnect.Agent.Services;

namespace Pconnect.Agent;

internal sealed class PairingForm : Form
{
    private readonly Label _codeLabel;
    private readonly Label _urlLabel;
    private readonly Timer _timer;
    private readonly AgentRuntime _runtime;

    public PairingForm(AgentRuntime runtime, string code)
    {
        _runtime = runtime;

        Text = "Pconnect Pairing";
        Width = 420;
        Height = 220;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        var title = new Label
        {
            Text = "Enter this code on your phone:",
            AutoSize = true,
            Left = 18,
            Top = 18,
        };

        _codeLabel = new Label
        {
            Text = code,
            AutoSize = true,
            Font = new Font(FontFamily.GenericSansSerif, 28, FontStyle.Bold),
            Left = 18,
            Top = 45,
        };

        _urlLabel = new Label
        {
            Text = runtime.GetLikelyWebSocketUrl() ?? "ws://<this-pc-ip>:47821/ws",
            AutoSize = true,
            Left = 18,
            Top = 115,
        };

        var copyButton = new Button
        {
            Text = "Copy URL",
            Left = 18,
            Top = 145,
            Width = 90,
        };
        copyButton.Click += (_, _) =>
        {
            var url = runtime.GetLikelyWebSocketUrl();
            if (url is not null)
            {
                Clipboard.SetText(url);
            }
        };

        var closeButton = new Button
        {
            Text = "Close",
            Left = 120,
            Top = 145,
            Width = 90,
        };
        closeButton.Click += (_, _) => Close();

        Controls.Add(title);
        Controls.Add(_codeLabel);
        Controls.Add(_urlLabel);
        Controls.Add(copyButton);
        Controls.Add(closeButton);

        _timer = new Timer { Interval = 1000 };
        _timer.Tick += (_, _) => RefreshCode();
        _timer.Start();
    }

    public void SetCode(string code) => _codeLabel.Text = code;

    private void RefreshCode()
    {
        // Keep the displayed code in sync with the runtime’s rotating code.
        var current = _runtime.Pairing.CurrentCode;
        if (!string.Equals(_codeLabel.Text, current, StringComparison.Ordinal))
        {
            _codeLabel.Text = current;
        }

        var url = _runtime.GetLikelyWebSocketUrl();
        if (url is not null && !string.Equals(_urlLabel.Text, url, StringComparison.Ordinal))
        {
            _urlLabel.Text = url;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Stop();
            _timer.Dispose();
        }

        base.Dispose(disposing);
    }
}
