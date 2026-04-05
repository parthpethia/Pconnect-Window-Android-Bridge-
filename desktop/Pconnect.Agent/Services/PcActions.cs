using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Pconnect.Agent.Services;

internal sealed class PcActions
{
    private readonly KeyboardInjector _keyboard = new();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool LockWorkStation();

    public void Lock() => LockWorkStation();

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
}
