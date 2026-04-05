using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal sealed class KeyboardInjector
{
    private const int INPUT_MOUSE = 0;
    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;

    private const ushort VK_BACK = 0x08;
    private const ushort VK_LWIN = 0x5B;
    private const ushort VK_L = 0x4C;

    // IMPORTANT: INPUT must match the Win32 INPUT struct size/layout.
    // On 64-bit Windows, sizeof(INPUT) is 40 bytes because the union must be
    // large enough for MOUSEINPUT (which contains a pointer-sized dwExtraInfo).
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public void MoveMouseBy(int dx, int dy)
    {
        if (dx == 0 && dy == 0)
        {
            return;
        }

        var inputs = new[]
        {
            Mouse(dx, dy, 0, MOUSEEVENTF_MOVE),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void ScrollWheel(int wheelDelta)
    {
        if (wheelDelta == 0)
        {
            return;
        }

        var inputs = new[]
        {
            Mouse(0, 0, unchecked((uint)wheelDelta), MOUSEEVENTF_WHEEL),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void LeftDown() => MouseButton(MOUSEEVENTF_LEFTDOWN);
    public void LeftUp() => MouseButton(MOUSEEVENTF_LEFTUP);
    public void RightDown() => MouseButton(MOUSEEVENTF_RIGHTDOWN);
    public void RightUp() => MouseButton(MOUSEEVENTF_RIGHTUP);
    public void MiddleDown() => MouseButton(MOUSEEVENTF_MIDDLEDOWN);
    public void MiddleUp() => MouseButton(MOUSEEVENTF_MIDDLEUP);

    public void LeftClick()
    {
        var inputs = new[]
        {
            Mouse(0, 0, 0, MOUSEEVENTF_LEFTDOWN),
            Mouse(0, 0, 0, MOUSEEVENTF_LEFTUP),
        };
        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void RightClick()
    {
        var inputs = new[]
        {
            Mouse(0, 0, 0, MOUSEEVENTF_RIGHTDOWN),
            Mouse(0, 0, 0, MOUSEEVENTF_RIGHTUP),
        };
        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void MiddleClick()
    {
        var inputs = new[]
        {
            Mouse(0, 0, 0, MOUSEEVENTF_MIDDLEDOWN),
            Mouse(0, 0, 0, MOUSEEVENTF_MIDDLEUP),
        };
        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void SendVk(ushort vk)
    {
        var inputs = new[]
        {
            Key(vk, '\0', 0),
            Key(vk, '\0', KEYEVENTF_KEYUP),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void SendVkDown(ushort vk, bool extended)
    {
        var inputs = new[]
        {
            Key(vk, '\0', extended ? KEYEVENTF_EXTENDEDKEY : 0),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void SendVkUp(ushort vk, bool extended)
    {
        var inputs = new[]
        {
            Key(vk, '\0', (extended ? KEYEVENTF_EXTENDEDKEY : 0) | KEYEVENTF_KEYUP),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void SendWinL()
    {
        var inputs = new[]
        {
            Key(VK_LWIN, '\0', KEYEVENTF_EXTENDEDKEY),
            Key(VK_L, '\0', 0),
            Key(VK_L, '\0', KEYEVENTF_KEYUP),
            Key(VK_LWIN, '\0', KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void SendBackspaces(int count)
    {
        if (count <= 0)
        {
            return;
        }

        var inputs = new INPUT[count * 2];
        var idx = 0;
        for (var i = 0; i < count; i++)
        {
            inputs[idx++] = Key(VK_BACK, '\0', 0);
            inputs[idx++] = Key(VK_BACK, '\0', KEYEVENTF_KEYUP);
        }

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    public void SendUnicode(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        // Each char becomes down+up.
        var inputs = new INPUT[text.Length * 2];
        var idx = 0;
        foreach (var ch in text)
        {
            inputs[idx++] = Key(0, ch, KEYEVENTF_UNICODE);
            inputs[idx++] = Key(0, ch, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        }

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT Key(ushort vk, char scan, uint flags)
    {
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = scan,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = 0,
                }
            }
        };
    }

    private void MouseButton(uint flags)
    {
        var inputs = new[]
        {
            Mouse(0, 0, 0, flags),
        };

        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT Mouse(int dx, int dy, uint mouseData, uint flags)
    {
        return new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = dx,
                    dy = dy,
                    mouseData = mouseData,
                    dwFlags = flags,
                    time = 0,
                    dwExtraInfo = 0,
                }
            }
        };
    }
}
