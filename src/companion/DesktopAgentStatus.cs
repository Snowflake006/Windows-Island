using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows.Automation;
using System.Runtime.InteropServices;

// Reads control metadata only. Never invoke controls, read the prompt value,
// enumerate message text, capture the screen, or inject into the application.
public sealed class DesktopAgentSnapshot {
    public string State = "unknown";
    public bool HasComposer;
    public bool HasStop;
    public bool Unavailable;
    public bool HasWorkComposer;
    public bool HasAction;
    public bool HasGenericComposer;
    public int ControlCount;
    public string Scope = "window";
    public string Mode = "unknown";
}

public static class IslandDesktopAgentReader {
    // Only the mode hint is retained. Never retain AutomationElement document
    // objects: Chromium can keep their hidden-document tree frozen indefinitely.
    static readonly Dictionary<IntPtr, string> OpenAIModes = new Dictionary<IntPtr, string>();
    public static bool IsGenericComposer(string id) {
        return Regex.IsMatch(id ?? "", @"^(prompt-textarea|chat-composer|chat-input|composer-input)$", RegexOptions.IgnoreCase);
    }
    public static string ResolveOpenAIMode(bool chat, bool work, string previous) {
        if (chat && !work) return "chat";
        if (work && !chat) return "work";
        return previous == "chat" || previous == "work" ? previous : "unknown";
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
    delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out WindowRect rectangle);
    [StructLayout(LayoutKind.Sequential)] struct WindowRect { public int Left, Top, Right, Bottom; }
    public static IntPtr FindDesktopWindow(int[] processIds) {
        var ids = new HashSet<int>(processIds ?? new int[0]);
        ids.Remove(0);
        if (ids.Count == 0) return IntPtr.Zero;
        IntPtr visible = IntPtr.Zero, hidden = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!ids.Contains(WindowProcessId(window))) return true;
            if (IsIconic(window)) { if (hidden == IntPtr.Zero) hidden = window; return true; }
            WindowRect rect;
            if (!GetWindowRect(window, out rect) || rect.Right-rect.Left < 200 || rect.Bottom-rect.Top < 150) return true;
            if (IsWindowVisible(window) && !IsIconic(window)) { visible = window; return false; }
            if (hidden == IntPtr.Zero) hidden = window;
            return true;
        }, IntPtr.Zero);
        return visible != IntPtr.Zero ? visible : hidden;
    }
    public static int WindowProcessId(IntPtr window) { uint id; GetWindowThreadProcessId(window, out id); return (int)id; }
    public static bool IsStopButton(string name) {
        return Regex.IsMatch(name ?? "", @"^(停止(生成|回答|回复|响应|回应|思考|流式传输|流式输出)?|取消生成|Stop( generating| generation| response| responding| thinking| streaming)?|Cancel (response|generation))(\s*[（(].*[）)])?$", RegexOptions.IgnoreCase);
    }
    public static bool IsComposer(string name) {
        return Regex.IsMatch(name ?? "", @"Gemini.*(提示|输入)|为 Gemini 输入提示|问问 Gemini|Ask Gemini|Enter a prompt|Message Gemini", RegexOptions.IgnoreCase);
    }
    public static bool IsChatComposer(string name) {
        return Regex.IsMatch(name ?? "", @"^(询问 ChatGPT|向 ChatGPT 发送消息|询问任何问题|Ask ChatGPT|Message ChatGPT|Ask anything)$", RegexOptions.IgnoreCase);
    }
    public static bool IsWorkComposer(string name) {
        return Regex.IsMatch(name ?? "", @"^(使用 ChatGPT Work|Use ChatGPT Work|Message Codex|Ask Codex|向 Codex 发送消息)$", RegexOptions.IgnoreCase);
    }
    public static bool IsActionButton(string name) {
        return Regex.IsMatch(name ?? "", @"^(正在等待你的回答|Waiting for your (answer|response)|批准|批准一次|允许一次|允许本次|Allow once|Approve once|Approve|Allow)$", RegexOptions.IgnoreCase);
    }
    public static string ClassifyOpenAI(bool chat, bool work, bool stop, bool action) {
        if (chat && !work) return stop ? "chat_thinking" : "complete";
        if (work && !chat) return action ? "action" : stop ? "thinking" : "complete";
        return "unknown";
    }
    public static string Classify(bool hasStop, bool hasComposer) {
        return hasStop ? "thinking" : hasComposer ? "ready" : "unknown";
    }
    public static DesktopAgentSnapshot ReadWindow(IntPtr handle) {
        return ReadWindow(handle, "Gemini");
    }
    public static DesktopAgentSnapshot ReadWindow(IntPtr handle, string provider) {
        var result = new DesktopAgentSnapshot();
        if (handle == IntPtr.Zero) { result.Unavailable = true; return result; }
        try {
            bool background = !IsWindowVisible(handle) || IsIconic(handle);
            var root = AutomationElement.FromHandle(handle);
            result.Scope = "fresh-window";
            if (root == null) { result.Unavailable = true; return result; }
            var condition = new OrCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
            // Cache only role/name/enabled. In particular, never request ValuePattern.
            {
                var cache = new CacheRequest();
                cache.Add(AutomationElement.NameProperty);
                cache.Add(AutomationElement.ControlTypeProperty);
                cache.Add(AutomationElement.IsEnabledProperty);
                cache.Add(AutomationElement.IsOffscreenProperty);
                cache.Add(AutomationElement.AutomationIdProperty);
                cache.AutomationElementMode = AutomationElementMode.Full;
                cache.TreeScope = TreeScope.Element;
                using (cache.Activate()) {
                    var controls = root.FindAll(TreeScope.Descendants, condition);
                    result.ControlCount = controls.Count;
                    for (int i = 0; i < controls.Count; i++) {
                        var info = controls[i].Cached;
                        if (!info.IsEnabled) continue;
                        // A minimized/tray window marks its entire tree offscreen.
                        // Its stop/composer metadata still describes the live turn.
                        if (provider == "ChatGPT" && info.IsOffscreen &&
                            IsWindowVisible(handle) && !IsIconic(handle)) continue;
                        if (info.ControlType == ControlType.Button && IsStopButton(info.Name)) result.HasStop = true;
                        if (provider == "ChatGPT" && info.ControlType == ControlType.Button && IsActionButton(info.Name)) result.HasAction = true;
                        if (provider == "ChatGPT" && info.ControlType == ControlType.Edit) {
                            bool work = IsWorkComposer(info.Name), chat = IsChatComposer(info.Name);
                            result.HasWorkComposer |= work;
                            result.HasComposer |= chat;
                            result.HasGenericComposer |= IsGenericComposer(info.AutomationId);
                        } else if (info.ControlType == ControlType.Edit && IsComposer(info.Name)) result.HasComposer = true;
                    }
                }
            }
            if (provider == "ChatGPT") {
                string previous;
                OpenAIModes.TryGetValue(handle, out previous);
                result.Mode = ResolveOpenAIMode(result.HasComposer, result.HasWorkComposer, previous);
                bool readable = result.HasComposer || result.HasWorkComposer || result.HasGenericComposer || result.HasStop || result.HasAction;
                // A remembered mode alone is not evidence of completion. Require
                // a live composer/stop/action signal from the chosen document.
                if (readable && result.Mode != "unknown") {
                    result.State = ClassifyOpenAI(result.Mode == "chat", result.Mode == "work", result.HasStop, result.HasAction);
                    OpenAIModes[handle] = result.Mode;
                } else result.Mode = "unknown";
            } else result.State = Classify(result.HasStop, result.HasComposer);
        } catch (ElementNotAvailableException) { result.Unavailable = true; }
          catch (InvalidOperationException) { result.Unavailable = true; }
          catch (System.Runtime.InteropServices.COMException) { result.Unavailable = true; }
        return result;
    }
}
