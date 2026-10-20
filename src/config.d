module config;

import farplugin;
import pluginsettings;
import dlgbuilder;
import wcharutil;

import core.sys.windows.windows : GUID, HANDLE, INVALID_HANDLE_VALUE;
import core.stdc.wchar_         : wcslen;
import std.conv                 : to;

// ──────────────────────────────────────────────────────────────
// Настройки плагина
// ──────────────────────────────────────────────────────────────
struct S3Config
{
    string endpoint         = "https://s3.amazonaws.com";
    string accessKeyId;
    string secretAccessKey;
    string region           = "us-east-1";
    string defaultBucket;
}

// ──────────────────────────────────────────────────────────────
// Замена LNG-файла — индексы кнопок
// ──────────────────────────────────────────────────────────────
private enum MsgId : int
{
    Ok     = 0,
    Cancel = 1,
}

private immutable wstring[2] g_Messages = [
    "  OK  "w,
    " Cancel "w,
];

// ──────────────────────────────────────────────────────────────
// Наследник PluginDialogBuilder с хардкодными строками
// ──────────────────────────────────────────────────────────────
private class S3DialogBuilder : PluginDialogBuilder
{
    this(in PluginStartupInfo* info,
         ref const GUID pluginGuid,
         ref const GUID dialogGuid,
         in wchar* title)
    {
        super(info, pluginGuid, dialogGuid, title, null);
    }

    override const(wchar)* GetLangString(int MessageID)
    {
        if (MessageID >= 0 && MessageID < cast(int) g_Messages.length)
            return g_Messages[MessageID].ptr;
        return "\0"w.ptr;
    }
}

// ──────────────────────────────────────────────────────────────
// Сохранение настроек
// ──────────────────────────────────────────────────────────────
void saveConfig(
    ref const PluginStartupInfo info,
    ref const GUID              pluginGuid,
    ref const S3Config          cfg)
{
    auto ps = new PluginSettings(pluginGuid, info.SettingsControl);
    scope(exit) destroy(ps);

    enum size_t ROOT = 0;
    ps.Set(ROOT, "Endpoint"w,        cfg.endpoint.to!wstring);
    ps.Set(ROOT, "AccessKeyId"w,     cfg.accessKeyId.to!wstring);
    ps.Set(ROOT, "SecretAccessKey"w, cfg.secretAccessKey.to!wstring);
    ps.Set(ROOT, "Region"w,          cfg.region.to!wstring);
    ps.Set(ROOT, "DefaultBucket"w,   cfg.defaultBucket.to!wstring);
}

// ──────────────────────────────────────────────────────────────
// Загрузка настроек
// ──────────────────────────────────────────────────────────────
S3Config loadConfig(
    ref const PluginStartupInfo info,
    ref const GUID              pluginGuid)
{
    S3Config cfg;

    auto ps = new PluginSettings(pluginGuid, info.SettingsControl);
    scope(exit) destroy(ps);

    enum size_t ROOT = 0;

    string fromW(wchar[] w)
    {
        return w.to!string;
    }

    auto ep  = ps.Get(ROOT, "Endpoint"w,       cfg.endpoint.to!(wchar[]));
    auto aki = ps.Get(ROOT, "AccessKeyId"w,     ""w.dup);
    auto sak = ps.Get(ROOT, "SecretAccessKey"w, ""w.dup);
    auto reg = ps.Get(ROOT, "Region"w,          cfg.region.to!(wchar[]));
    auto db  = ps.Get(ROOT, "DefaultBucket"w,   ""w.dup);

    if (ep.length  > 0) cfg.endpoint         = fromW(ep);
    if (aki.length > 0) cfg.accessKeyId       = fromW(aki);
    if (sak.length > 0) cfg.secretAccessKey   = fromW(sak);
    if (reg.length > 0) cfg.region            = fromW(reg);
    if (db.length  > 0) cfg.defaultBucket     = fromW(db);

    return cfg;
}

// ──────────────────────────────────────────────────────────────
// Диалог настроек
// ──────────────────────────────────────────────────────────────
bool showConfigDialog(
    ref const PluginStartupInfo info,
    ref const GUID              pluginGuid,
    ref const GUID              dialogGuid,
    ref S3Config                cfg)
{
    wchar[512] bufEndpoint;
    wchar[128] bufAccessKeyId;
    wchar[256] bufSecretAccessKey;
    wchar[64]  bufRegion;
    wchar[128] bufDefaultBucket;

    void fillBuf(wchar[] buf, string val)
    {
        auto w = val.to!wstring;
        size_t n = w.length < buf.length - 1 ? w.length : buf.length - 1;
        buf[0 .. n] = w[0 .. n];
        buf[n] = '\0';
    }

    fillBuf(bufEndpoint,        cfg.endpoint);
    fillBuf(bufAccessKeyId,     cfg.accessKeyId);
    fillBuf(bufSecretAccessKey, cfg.secretAccessKey);
    fillBuf(bufRegion,          cfg.region);
    fillBuf(bufDefaultBucket,   cfg.defaultBucket);

    auto dlg = new S3DialogBuilder(
        &info,
        pluginGuid,
        dialogGuid,
        "S3 Navigator \u2014 Settings"w.ptr
    );

    dlg.AddText("Endpoint:"w.ptr);
    dlg.AddEditField(bufEndpoint.ptr,        cast(int) bufEndpoint.length,        60);

    dlg.AddText("Access Key ID:"w.ptr);
    dlg.AddEditField(bufAccessKeyId.ptr,     cast(int) bufAccessKeyId.length,     40);

    dlg.AddText("Secret Access Key:"w.ptr);
    dlg.AddPasswordField(bufSecretAccessKey.ptr, cast(int) bufSecretAccessKey.length, 40);

    dlg.AddText("Region:"w.ptr);
    dlg.AddEditField(bufRegion.ptr,          cast(int) bufRegion.length,          20);

    dlg.AddText("Default Bucket (optional):"w.ptr);
    dlg.AddEditField(bufDefaultBucket.ptr,   cast(int) bufDefaultBucket.length,   40);

    // AddOKCancel теперь берёт строки из нашего GetLangString
    dlg.AddOKCancel(MsgId.Ok, MsgId.Cancel);

    if (!dlg.ShowDialog())
        return false;

    string fromBuf(wchar[] buf)
    {
        size_t len = wcslen(buf.ptr);
        return buf[0 .. len].to!string;
    }

    cfg.endpoint         = fromBuf(bufEndpoint);
    cfg.accessKeyId       = fromBuf(bufAccessKeyId);
    cfg.secretAccessKey   = fromBuf(bufSecretAccessKey);
    cfg.region            = fromBuf(bufRegion);
    cfg.defaultBucket     = fromBuf(bufDefaultBucket);

    return true;
}
