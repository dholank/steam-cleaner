using System;
using System.Threading;
public class ProcessFixture {
    public static int Main(string[] args) {
        string mode = args[Array.IndexOf(args, "+login") + 1];
        if (mode == "arguments") { System.IO.File.WriteAllLines("arguments.txt", args); return 0; }
        if (mode == "directory") { System.IO.File.WriteAllText("cwd.txt", Environment.CurrentDirectory); return 0; }
        if (mode == "timeout") { Thread.Sleep(10000); return 0; }
        if (mode == "license") { Console.Error.WriteLine("ERROR! no subscription"); return 0; }
        if (mode == "guard") { Console.WriteLine("Steam Guard required"); return 0; }
        if (mode == "failure") { return 37; }
        Console.Error.Write(new string('x', 100000));
        Console.Write(new string('y', 100000));
        return 0;
    }
}
