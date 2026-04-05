using Pconnect.Agent.Services;

namespace Pconnect.Agent;

internal sealed class TrayAppContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly AgentRuntime _runtime;
    private PairingForm? _pairingForm;
    private readonly SynchronizationContext _uiContext;

    public TrayAppContext()
    {
        _uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _runtime = new AgentRuntime(new UiActions(this));
        _runtime.Start();

        var menu = new ContextMenuStrip();
        var showPairItem = new ToolStripMenuItem("Show pairing code", null, (_, _) => ShowPairingCode());
        var copyWsItem = new ToolStripMenuItem("Copy WebSocket URL", null, (_, _) => CopyWebSocketUrl());
        var exitItem = new ToolStripMenuItem("Exit", null, (_, _) => Exit());
        menu.Items.Add(showPairItem);
        menu.Items.Add(copyWsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(exitItem);

        _tray = new NotifyIcon
        {
            Text = "Pconnect Agent",
            Visible = true,
            Icon = SystemIcons.Application,
            ContextMenuStrip = menu,
        };
        _tray.DoubleClick += (_, _) => ShowPairingCode();
    }

    private void ShowPairingCode()
    {
        var code = _runtime.Pairing.CurrentCode;

        if (_pairingForm is null || _pairingForm.IsDisposed)
        {
            _pairingForm = new PairingForm(_runtime, code);
            _pairingForm.FormClosed += (_, _) => _pairingForm = null;
            _pairingForm.Show();
        }
        else
        {
            _pairingForm.SetCode(code);
            _pairingForm.Show();
        }

        _pairingForm.BringToFront();
        _pairingForm.Activate();
    }

    private void CopyWebSocketUrl()
    {
        var url = _runtime.GetLikelyWebSocketUrl();
        if (url is null)
        {
            MessageBox.Show("Could not determine an IP address. Use manual IP on the phone.", "Pconnect", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        Clipboard.SetText(url);
        _tray.ShowBalloonTip(2000, "Pconnect", "WebSocket URL copied to clipboard", ToolTipIcon.Info);
    }

    private void Exit()
    {
        _tray.Visible = false;
        _tray.Dispose();
        _runtime.Dispose();
        Application.Exit();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _runtime.Dispose();
        }

        base.Dispose(disposing);
    }

    private sealed class UiActions : IUiActions
    {
        private readonly TrayAppContext _ctx;

        public UiActions(TrayAppContext ctx) => _ctx = ctx;

        public void ShowAgentUi() => _ctx.PostToUi(_ctx.ShowPairingCode);
    }

    private void PostToUi(Action action)
    {
        _uiContext.Post(_ => action(), null);
    }
}
