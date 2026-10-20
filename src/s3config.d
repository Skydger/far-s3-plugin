module s3config;

import core.sys.windows.windows : MAX_PATH, DWORD,
                                   GetEnvironmentVariableW;
import std.conv   : to;
import std.file   : read, write, exists, mkdirRecurse;
import std.format : format;
import std.json;
import std.path   : buildPath, dirName;
import s3log      : debugLog;

struct S3Profile
{
    string name;
    string endpoint;
    string bucket;
    string accessKeyId;
    string secretKey;
    string region;
}

struct S3Settings
{
    S3Profile[] profiles;
}

string settingsPath()
{
    wchar[MAX_PATH] buf;
    DWORD len = GetEnvironmentVariableW(
        "LOCALAPPDATA\0"w.ptr,
        buf.ptr,
        cast(DWORD) buf.length);

    string base = (len > 0 && len < buf.length)
                  ? buf[0 .. len].to!string
                  : "C:\\Temp";

    return buildPath(
        base,
        "Far Manager",
        "Profile",
        "PluginsData",
        "far-s3-navigator",
        "settings.json");
}

// src/s3config.d — добавляем миграцию старого формата

S3Settings loadSettings(string path)
{
    S3Settings result;

    // ── Пробуем загрузить новый формат ───────────────────
    if (exists(path))
    {
        try
        {
            auto json = parseJSON(cast(string) read(path));
            if ("profiles" in json.object)
            {
                foreach (ref p; json["profiles"].array)
                {
                    S3Profile profile;
                    profile.name        = p["name"].str;
                    profile.endpoint    = p["endpoint"].str;
                    profile.accessKeyId = p["accessKeyId"].str;
                    profile.secretKey   = p["secretKey"].str;
                    profile.region      = ("region" in p.object)
                                          ? p["region"].str
                                          : "us-east-1";
                    profile.bucket      = ("bucket" in p.object)
                                          ? p["bucket"].str
                                          : "";
                    result.profiles ~= profile;
                }
                debugLog("loadSettings: loaded " ~
                         result.profiles.length.to!string ~
                         " profiles");
                return result;
            }
        }
        catch (Exception e)
        {
            debugLog("loadSettings error: " ~ e.msg);
        }
    }

    // ── Фолбек: ищем старый конфиг ───────────────────────
    // Старый формат хранился рядом с плагином или в реестре —
    // укажи где именно и мигрируем
    string oldPath = buildPath(
        dirName(path), "..", "far-s3-plugin", "config.json");

    if (exists(oldPath))
    {
        debugLog("loadSettings: migrating from " ~ oldPath);
        try
        {
            auto json = parseJSON(cast(string) read(oldPath));

            S3Profile profile;
            profile.name        = "Default";
            profile.endpoint    = json["endpoint"].str;
            profile.accessKeyId = json["accessKeyId"].str;
            profile.secretKey   = json["secretKey"].str;
            profile.region      = ("region" in json.object)
                                  ? json["region"].str
                                  : "us-east-1";
            profile.bucket      = ("bucket" in json.object)
                                  ? json["bucket"].str
                                  : "";
            result.profiles ~= profile;

            // Сохраняем в новом формате
            saveSettings(path, result);
            debugLog("loadSettings: migration done");
        }
        catch (Exception e)
        {
            debugLog("loadSettings migration error: " ~ e.msg);
        }
    }

    return result;
}

void saveSettings(string path, ref S3Settings settings)
{
    try
    {
        auto profiles = JSONValue(JSONValue[].init);
        foreach (ref p; settings.profiles)
        {
            JSONValue entry = JSONValue(
                (JSONValue[string]).init);
            entry["name"]        = JSONValue(p.name);
            entry["endpoint"]    = JSONValue(p.endpoint);
            entry["accessKeyId"] = JSONValue(p.accessKeyId);
            entry["secretKey"]   = JSONValue(p.secretKey);
            entry["region"]      = JSONValue(p.region);
            if (p.bucket.length > 0)
                entry["bucket"]  = JSONValue(p.bucket);
            profiles.array ~= entry;
        }

        JSONValue root = JSONValue((JSONValue[string]).init);
        root["profiles"] = profiles;

        mkdirRecurse(dirName(path));
        write(path, root.toPrettyString());
        debugLog("saveSettings: saved to " ~ path);
    }
    catch (Exception e)
    {
        debugLog("saveSettings error: " ~ e.msg);
    }
}
