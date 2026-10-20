module s3log;

import core.sys.windows.windows;
import std.conv   : to;
import std.file   : append, exists, mkdirRecurse;
import std.format : format;
import std.path   : buildPath, dirName;

private __gshared string g_logPath;
private __gshared bool   g_initialized;

private string resolveLogPath()
{
    // Читаем %LOCALAPPDATA% через WinAPI
    wchar[MAX_PATH] buf;
    DWORD len = GetEnvironmentVariableW(
        "LOCALAPPDATA\0"w.ptr,
        buf.ptr,
        cast(DWORD) buf.length);

    string localAppData;
    if (len > 0 && len < buf.length)
        localAppData = buf[0 .. len].to!string;
    else
        localAppData = "C:\\Temp";  // фолбек

    return buildPath(
        localAppData,
        "Far Manager",
        "Profile",
        "PluginsData",
        "far-s3-navigator",
        "far-s3-navigator.log");
}

private string getLogPath()
{
    if (g_initialized) return g_logPath;
    g_initialized = true;
    try
    {
        g_logPath = resolveLogPath();
    }
    catch (Throwable e)
    {
        g_logPath = "C:\\Temp\\far-s3-plugin.log";
    }
    return g_logPath;
}

void debugLog(string message)
{
    try
    {
        string path = getLogPath();

        auto dir = dirName(path);
        if (!exists(dir))
            mkdirRecurse(dir);

        SYSTEMTIME st;
        GetLocalTime(&st);

        string line = "%04d-%02d-%02d %02d:%02d:%02d.%03d  %s\n"
            .format(
                st.wYear,   st.wMonth,  st.wDay,
                st.wHour,   st.wMinute, st.wSecond,
                st.wMilliseconds,
                message);

        append(path, line);
    }
    catch (Exception e) { }
}

void initLog()
{
    g_initialized = false;
    g_logPath     = "";
    debugLog("=== far-s3-plugin started ===");
    debugLog("Log: " ~ getLogPath());
}
