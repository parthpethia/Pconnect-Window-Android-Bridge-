using Pconnect.Agent.Services;

namespace Pconnect.Agent;

internal sealed class TrayAppContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly AgentRuntime _runtime;
    private PairingForm? _pairingForm;
    private DashboardForm? _dashboardForm;
    private readonly SynchronizationContext _uiContext;
    private readonly CancellationTokenSource _ipcCts = new();
    private readonly Task _ipcTask;

    public TrayAppContext()
    {
        _uiContext = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _runtime = new AgentRuntime(new UiActions(this));
        _runtime.Start();

        // Allow subsequent EXE launches to bring the dashboard back.
        _ipcTask = SingleInstanceIpc.RunServerAsync(() => PostToUi(ShowDashboard), _ipcCts.Token);

        var menu = new ContextMenuStrip();
        var dashboardItem = new ToolStripMenuItem("Dashboard", null, (_, _) => ShowDashboard());
        var showPairItem = new ToolStripMenuItem("Show pairing code", null, (_, _) => ShowPairingCode());
        var copyWsItem = new ToolStripMenuItem("Copy WebSocket URL", null, (_, _) => CopyWebSocketUrl());
        var exitItem = new ToolStripMenuItem("Exit", null, (_, _) => Exit());
        menu.Items.Add(dashboardItem);
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
        _tray.DoubleClick += (_, _) => ShowDashboard();

        if (!_runtime.IsDiscoveryEnabled && !string.IsNullOrWhiteSpace(_runtime.DiscoveryStartError))
        {
            _tray.ShowBalloonTip(6000, "Pconnect", _runtime.DiscoveryStartError, ToolTipIcon.Warning);
        }

        // Show dashboard when the exe is launched.
        PostToUi(ShowDashboard);
    }

    private void ShowDashboard()
    {
        if (_dashboardForm is null || _dashboardForm.IsDisposed)
        {
            _dashboardForm = new DashboardForm(_runtime);
            _dashboardForm.FormClosed += (_, _) => _dashboardForm = null;
            _dashboardForm.Show();
        }
        else
        {
            _dashboardForm.Show();
        }

        _dashboardForm.BringToFront();
        _dashboardForm.Activate();
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
        try
        {
            _ipcCts.Cancel();
        }
        catch
        {
            // ignore
        }

        if (_dashboardForm is not null && !_dashboardForm.IsDisposed)
        {
            _dashboardForm.AllowClose = true;
            _dashboardForm.Close();
        }

        _tray.Visible = false;
        _tray.Dispose();
        _runtime.Dispose();
        Application.Exit();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try
            {
                _ipcCts.Cancel();
            }
            catch
            {
                // ignore
            }

            _tray.Visible = false;
            _tray.Dispose();
            _runtime.Dispose();
            _ipcCts.Dispose();
        }

        base.Dispose(disposing);
    }

    private sealed class UiActions : IUiActions
    {
        private readonly TrayAppContext _ctx;

        public UiActions(TrayAppContext ctx) => _ctx = ctx;

        public void ShowAgentUi() => _ctx.PostToUi(_ctx.ShowDashboard);
    }

    private void PostToUi(Action action)
    {
        _uiContext.Post(_ => action(), null);
    }
}
