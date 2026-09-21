// DSH WebUI - 单文件启动器
// 把界面脚本内嵌为资源，运行时释放到临时目录并用隐藏窗口的 PowerShell 执行。
// 这样用户只需要一个 .exe：双击即可，不会有命令窗口，也不会误点到别的文件。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

internal static class Launcher
{
    private const string ResourceName = "DswWebUi.ui.ps1";
    // 图标也要释放：界面脚本的窗口标题栏和托盘图标都会去脚本所在目录找 app.ico。
    private const string IconResourceName = "DswWebUi.app.ico";
    private const string LogName = "ui-stderr.log";

    [STAThread]
    private static int Main(string[] args)
    {
        string launchDir = AppDomain.CurrentDomain.BaseDirectory;
        string stateDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "dsh-web-launcher");
        try { Directory.CreateDirectory(stateDir); }
        catch { }

        string logPath = Path.Combine(stateDir, LogName);
        string scriptPath = Path.Combine(Path.GetTempPath(), "dsh-webui-ui.ps1");
        string iconPath = Path.Combine(Path.GetTempPath(), "app.ico");

        try
        {
            Assembly self = Assembly.GetExecutingAssembly();
            using (Stream input = self.GetManifestResourceStream(ResourceName))
            {
                if (input == null)
                {
                    return Fail("内嵌脚本资源缺失：" + ResourceName);
                }
                using (var output = new FileStream(scriptPath, FileMode.Create, FileAccess.Write))
                {
                    // PowerShell 5.1 需要 BOM 才能按 UTF-8 解析中文注释，
                    // 但资源本身可能已经带 BOM。重复写入会造成文件头出现两个 BOM，
                    // 使 <# 不在首位、注释块失效，脚本启动即报 "意外的属性 CmdletBinding"。
                    var head = new byte[3];
                    int headLen = input.Read(head, 0, 3);
                    bool hasBom = headLen == 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF;
                    if (!hasBom)
                    {
                        byte[] bom = new byte[] { 0xEF, 0xBB, 0xBF };
                        output.Write(bom, 0, bom.Length);
                    }
                    if (hasBom) { output.Write(head, 0, head.Length); }
                    input.CopyTo(output);
                }
            }

            // 释放 app.ico 到与脚本同一目录，供窗口图标与托盘图标使用
            using (Stream iconIn = self.GetManifestResourceStream(IconResourceName))
            {
                if (iconIn != null)
                {
                    using (var iconOut = new FileStream(iconPath, FileMode.Create, FileAccess.Write))
                    {
                        iconIn.CopyTo(iconOut);
                    }
                }
            }

            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = launchDir;
            psi.EnvironmentVariables["DSH_WEBUI_WORKSPACE"] = launchDir;

            Process p = Process.Start(psi);
            if (p == null)
            {
                return Fail("无法启动 PowerShell 进程。");
            }
            return 0;
        }
        catch (Exception ex)
        {
            return Fail(ex.Message);
        }
    }

    private static int Fail(string message)
    {
        try
        {
            Console.Error.WriteLine("DSH WebUI 启动失败：" + message);
            Console.Error.WriteLine("按回车键关闭...");
            Console.ReadLine();
        }
        catch { }
        return 1;
    }
}
