using System.Drawing;
using System.Text.Json;
using Pconnect.Agent.Services;
using QRCoder;

namespace Pconnect.Agent;

internal sealed class PairingForm : Form
{
    private readonly Label _codeLabel;
    private readonly Label _urlLabel;
    private readonly PictureBox _qrPictureBox;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly AgentRuntime _runtime;

    public PairingForm(AgentRuntime runtime, string code)
    {
        _runtime = runtime;

        Text = "Pconnect Pairing";
        Width = 420;
        Height = 380;
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

        var qrLabel = new Label
        {
            Text = "Or scan this QR code:",
            AutoSize = true,
            Left = 18,
            Top = 140,
        };

        _qrPictureBox = new PictureBox
        {
            Left = 18,
            Top = 160,
            Width = 160,
            Height = 160,
            SizeMode = PictureBoxSizeMode.Zoom,
            BorderStyle = BorderStyle.FixedSingle,
        };
        UpdateQrCode(code);

        var copyButton = new Button
        {
            Text = "Copy URL",
            Left = 200,
            Top = 160,
            Width = 90,
        };
        copyButton.Click += (_, _) =>
        {
            var url = runtime.GetLikelyWebSocketUrl();
            if (url is not null) Clipboard.SetText(url);
        };

        var closeButton = new Button
        {
            Text = "Close",
            Left = 200,
            Top = 200,
            Width = 90,
        };
        closeButton.Click += (_, _) => Close();

        Controls.Add(title);
        Controls.Add(_codeLabel);
        Controls.Add(_urlLabel);
        Controls.Add(qrLabel);
        Controls.Add(_qrPictureBox);
        Controls.Add(copyButton);
        Controls.Add(closeButton);

        _timer = new System.Windows.Forms.Timer { Interval = 1000 };
        _timer.Tick += (_, _) => RefreshCode();
        _timer.Start();
    }

    public void SetCode(string code)
    {
        _codeLabel.Text = code;
        UpdateQrCode(code);
    }

    private void UpdateQrCode(string code)
    {
        try
        {
            var url = _runtime.GetLikelyWebSocketUrl();
            var ip = "0.0.0.0";
            var port = AgentRuntime.DefaultWsPort;

            if (url is not null)
            {
                var uri = new Uri(url);
                ip = uri.Host;
                port = uri.Port;
            }

            var qrData = JsonSerializer.Serialize(new
            {
                ip,
                port,
                pairingCode = code,
            });

            using var qrGenerator = new QRCodeGenerator();
            using var qrCodeData = qrGenerator.CreateQrCode(qrData, QRCodeGenerator.ECCLevel.M);
            using var qrCode = new PngByteQRCode(qrCodeData);
            var pngBytes = qrCode.GetGraphic(4);

            using var ms = new MemoryStream(pngBytes);
            var oldImage = _qrPictureBox.Image;
            _qrPictureBox.Image = Image.FromStream(ms);
            oldImage?.Dispose();
        }
        catch
        {
            // QR generation failed — leave blank
        }
    }

    private void RefreshCode()
    {
        // Keep the displayed code in sync with the runtime's rotating code.
        var current = _runtime.Pairing.CurrentCode;
        if (!string.Equals(_codeLabel.Text, current, StringComparison.Ordinal))
        {
            _codeLabel.Text = current;
            UpdateQrCode(current);
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
            _qrPictureBox.Image?.Dispose();
        }

        base.Dispose(disposing);
    }
}
