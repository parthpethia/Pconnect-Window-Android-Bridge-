using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal sealed class PcActions
{
    private readonly KeyboardInjector _keyboard = new();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool LockWorkStation();

    public bool Lock()
    {
        // Prefer the OS API. In some environments this may return false (policy/session issues).
        if (LockWorkStation())
        {
            return true;
        }

        // Fallback #1: rundll32 invocation of the same API.
        try
        {
            using var p = Process.Start(new ProcessStartInfo
            {
                FileName = "rundll32.exe",
                Arguments = "user32.dll,LockWorkStation",
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (p is not null)
            {
                return true;
            }
        }
        catch
        {
            // ignore
        }

        // Fallback #2: simulate Win+L.
        try
        {
            _keyboard.SendWinL();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void TypeText(int backspaces, string text)
    {
        if (backspaces > 0)
        {
            _keyboard.SendBackspaces(backspaces);
        }

        if (!string.IsNullOrEmpty(text))
        {
            _keyboard.SendUnicode(text);
        }
    }

    public void Launch(string command, IReadOnlyList<string>? args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = command,
            UseShellExecute = true,
        };

        if (args is not null)
        {
            foreach (var a in args)
            {
                psi.ArgumentList.Add(a);
            }
        }

        Process.Start(psi);
    }

    public void MouseMove(int dx, int dy)
    {
        _keyboard.MoveMouseBy(dx, dy);
    }

    public void MouseScroll(int wheelDelta)
    {
        _keyboard.ScrollWheel(wheelDelta);
    }

    public void MouseButton(string button, string action)
    {
        // Normalize
        button = button.Trim().ToLowerInvariant();
        action = action.Trim().ToLowerInvariant();

        if (action == "click")
        {
            switch (button)
            {
                case "left":
                    _keyboard.LeftClick();
                    return;
                case "right":
                    _keyboard.RightClick();
                    return;
                case "middle":
                    _keyboard.MiddleClick();
                    return;
            }
        }

        if (action == "down")
        {
            switch (button)
            {
                case "left":
                    _keyboard.LeftDown();
                    return;
                case "right":
                    _keyboard.RightDown();
                    return;
                case "middle":
                    _keyboard.MiddleDown();
                    return;
            }
        }

        if (action == "up")
        {
            switch (button)
            {
                case "left":
                    _keyboard.LeftUp();
                    return;
                case "right":
                    _keyboard.RightUp();
                    return;
                case "middle":
                    _keyboard.MiddleUp();
                    return;
            }
        }
    }

    public void Key(ushort vk, string action, bool extended)
    {
        action = action.Trim().ToLowerInvariant();

        switch (action)
        {
            case "press":
                _keyboard.SendVk(vk);
                break;
            case "down":
                _keyboard.SendVkDown(vk, extended);
                break;
            case "up":
                _keyboard.SendVkUp(vk, extended);
                break;
        }
    }

    public bool SetVolume(int level)
    {
        return SystemVolume.TrySetPercent(level);
    }

    public bool SetBrightness(int level)
    {
        return SystemBrightness.TrySetPercent(level);
    }

    public bool Shutdown()
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo
            {
                FileName = "shutdown.exe",
                Arguments = "/s /t 0",
                UseShellExecute = false,
                CreateNoWindow = true,
            });

            return p is not null;
        }
        catch
        {
            return false;
        }
    }
}
