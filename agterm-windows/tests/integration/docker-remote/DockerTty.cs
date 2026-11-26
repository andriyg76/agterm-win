using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// docker-tty runs docker.exe with its arguments, adding -t after the first when stdin is a console. A pane's attach runs
// in a ConPTY and needs docker's pty and raw input (docker exec -i alone reads the console cooked, by line); every other
// remote call runs on pipes, where -t fails with "the input device is not a TTY". wsl.exe makes this choice itself.
public static class DockerTty {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle, out uint mode);

    public static int Main(string[] args) {
        uint mode;
        var words = new List<string>(args);
        if (words.Count > 0 && GetConsoleMode(GetStdHandle(-10), out mode)) words.Insert(1, "-t");
        var start = new ProcessStartInfo("docker.exe", Join(words)) { UseShellExecute = false };
        using (var process = Process.Start(start)) {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    // Join quotes each word as CommandLineToArgvW, and docker's Go runtime, split it back.
    static string Join(List<string> words) {
        var line = new StringBuilder();
        foreach (var word in words) {
            if (line.Length > 0) line.Append(' ');
            if (word.Length > 0 && word.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) { line.Append(word); continue; }
            line.Append('"');
            int slashes = 0;
            foreach (var c in word) {
                if (c == '\\') { slashes++; continue; }
                line.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c);
                slashes = 0;
            }
            line.Append('\\', slashes * 2).Append('"');
        }
        return line.ToString();
    }
}
