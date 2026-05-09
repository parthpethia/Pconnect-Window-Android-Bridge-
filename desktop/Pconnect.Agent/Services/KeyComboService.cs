using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

/// <summary>
/// Executes keyboard shortcut combos from named key arrays (e.g. ["ctrl", "shift", "esc"]).
/// All modifier keys are pressed down, then the final key is pressed + released,
/// and finally all modifiers are released in reverse order.
/// </summary>
internal static class KeyComboService
{
    private const int INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const uint KEYEVENTF_KEYUP = 0x0002;

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
        public nuint dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    private static extern nuint GetMessageExtraInfo();

    // Modifier keys
    private static readonly HashSet<string> Modifiers = new(StringComparer.OrdinalIgnoreCase)
    {
        "ctrl", "control", "shift", "alt", "win", "windows", "lwin", "rwin", "meta", "super"
    };

    /// <summary>
    /// Executes a key combo from an array of named keys.
    /// Returns true if all keys were recognized and sent.
    /// </summary>
    public static bool Execute(IReadOnlyList<string> keys)
    {
        if (keys == null || keys.Count == 0) return false;

        var inputs = new List<INPUT>();

        // Separate modifiers and action keys
        var modifierVks = new List<(ushort vk, bool extended)>();
        var actionVks = new List<(ushort vk, bool extended)>();

        foreach (var key in keys)
        {
            var resolved = ResolveKey(key.Trim().ToLowerInvariant());
            if (resolved == null) return false;

            if (Modifiers.Contains(key.Trim()))
            {
                modifierVks.Add(resolved.Value);
            }
            else
            {
                actionVks.Add(resolved.Value);
            }
        }

        // Press modifiers down
        foreach (var (vk, ext) in modifierVks)
        {
            inputs.Add(KeyDown(vk, ext));
        }

        // Send modifier key-downs first
        if (inputs.Count > 0)
        {
            var modArr = inputs.ToArray();
            SendInput((uint)modArr.Length, modArr, Marshal.SizeOf<INPUT>());
            Thread.Sleep(30); // Allow OS to register modifier state
        }

        // Press and release action keys
        var actionInputs = new List<INPUT>();
        foreach (var (vk, ext) in actionVks)
        {
            actionInputs.Add(KeyDown(vk, ext));
            actionInputs.Add(KeyUp(vk, ext));
        }

        if (actionInputs.Count > 0)
        {
            var actArr = actionInputs.ToArray();
            SendInput((uint)actArr.Length, actArr, Marshal.SizeOf<INPUT>());
            Thread.Sleep(30); // Allow OS to register key press
        }

        // Release modifiers in reverse
        var releaseInputs = new List<INPUT>();
        for (int i = modifierVks.Count - 1; i >= 0; i--)
        {
            var (vk, ext) = modifierVks[i];
            releaseInputs.Add(KeyUp(vk, ext));
        }

        if (releaseInputs.Count > 0)
        {
            var relArr = releaseInputs.ToArray();
            SendInput((uint)relArr.Length, relArr, Marshal.SizeOf<INPUT>());
        }

        return true;
    }

    private static (ushort vk, bool extended)? ResolveKey(string key)
    {
        return key switch
        {
            // Modifiers
            "ctrl" or "control" => (0x11, false),    // VK_CONTROL
            "shift" => (0x10, false),                 // VK_SHIFT
            "alt" => (0x12, false),                   // VK_MENU
            "win" or "windows" or "lwin" or "meta" or "super" => (0x5B, true), // VK_LWIN
            "rwin" => (0x5C, true),                   // VK_RWIN

            // Navigation
            "enter" or "return" => (0x0D, false),
            "tab" => (0x09, false),
            "esc" or "escape" => (0x1B, false),
            "space" => (0x20, false),
            "backspace" => (0x08, false),
            "delete" or "del" => (0x2E, true),
            "insert" or "ins" => (0x2D, true),
            "home" => (0x24, true),
            "end" => (0x23, true),
            "pageup" or "pgup" => (0x21, true),
            "pagedown" or "pgdn" => (0x22, true),

            // Arrow keys
            "up" => (0x26, true),
            "down" => (0x28, true),
            "left" => (0x25, true),
            "right" => (0x27, true),

            // Function keys
            "f1" => (0x70, false),
            "f2" => (0x71, false),
            "f3" => (0x72, false),
            "f4" => (0x73, false),
            "f5" => (0x74, false),
            "f6" => (0x75, false),
            "f7" => (0x76, false),
            "f8" => (0x77, false),
            "f9" => (0x78, false),
            "f10" => (0x79, false),
            "f11" => (0x7A, false),
            "f12" => (0x7B, false),

            // Special
            "printscreen" or "prtsc" => (0x2C, false),
            "scrolllock" => (0x91, false),
            "pause" => (0x13, false),
            "capslock" => (0x14, false),
            "numlock" => (0x90, false),

            // Letters a-z → VK 0x41-0x5A
            var s when s.Length == 1 && s[0] >= 'a' && s[0] <= 'z' =>
                ((ushort)(0x41 + (s[0] - 'a')), false),

            // Digits 0-9 → VK 0x30-0x39
            var s when s.Length == 1 && s[0] >= '0' && s[0] <= '9' =>
                ((ushort)(0x30 + (s[0] - '0')), false),

            // Punctuation
            ";" or "semicolon" => (0xBA, false),
            "=" or "equals" or "plus" => (0xBB, false),
            "," or "comma" => (0xBC, false),
            "-" or "minus" or "hyphen" => (0xBD, false),
            "." or "period" => (0xBE, false),
            "/" or "slash" => (0xBF, false),
            "`" or "backtick" or "tilde" => (0xC0, false),
            "[" or "lbracket" => (0xDB, false),
            "\\" or "backslash" => (0xDC, false),
            "]" or "rbracket" => (0xDD, false),
            "'" or "quote" => (0xDE, false),

            _ => null,
        };
    }

    private static INPUT KeyDown(ushort vk, bool extended)
    {
        var scan = (ushort)MapVirtualKey(vk, 0); // MAPVK_VK_TO_VSC
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = scan,
                    dwFlags = extended ? KEYEVENTF_EXTENDEDKEY : 0,
                    time = 0,
                    dwExtraInfo = GetMessageExtraInfo(),
                }
            }
        };
    }

    private static INPUT KeyUp(ushort vk, bool extended)
    {
        var scan = (ushort)MapVirtualKey(vk, 0); // MAPVK_VK_TO_VSC
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = scan,
                    dwFlags = (extended ? KEYEVENTF_EXTENDEDKEY : 0) | KEYEVENTF_KEYUP,
                    time = 0,
                    dwExtraInfo = GetMessageExtraInfo(),
                }
            }
        };
    }
}
