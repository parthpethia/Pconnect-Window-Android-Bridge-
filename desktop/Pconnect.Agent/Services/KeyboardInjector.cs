using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal sealed class KeyboardInjector
{
    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    private const ushort VK_BACK = 0x08;

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public nint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

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
            inputs[idx++] = Key(VK_BACK, 0, 0);
            inputs[idx++] = Key(VK_BACK, 0, KEYEVENTF_KEYUP);
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
}
