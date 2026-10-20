module s3panel;

import farplugin;
import s3.client;
import config;
import s3log;
import s3config;

import std.string         : lastIndexOf;
import core.stdc.wchar_   : wcslen;
import core.stdc.string   : memset;
import std.conv           : to;
import std.format;
import core.sys.windows.windows : FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL;

// src/s3panel.d — переименовываем PanelMode → S3PanelMode
enum S3PanelMode
{
    Profiles,
    Buckets,
    Objects,
}
// ──────────────────────────────────────────────────────────────
// Состояние панели
// ──────────────────────────────────────────────────────────────
struct S3PanelState
{
    S3PanelMode mode         = S3PanelMode.Profiles;
    int         profileIndex = -1;
    string      currentBucket;
    string      currentPrefix;
    string      pendingCursorName;
    int         pendingCursorIndex = -1; 

    PluginPanelItem[] items;
    wstring[]         itemNames;

    S3Settings* settings;   // ← вместо старого config

    ref S3Profile currentProfile()
    {
        assert(profileIndex >= 0 &&
               profileIndex < cast(int) settings.profiles.length);
        return settings.profiles[profileIndex];
    }

    S3Client makeClient()
    {
        auto p = currentProfile();
        S3Client client;
        client.endpoint = p.endpoint;
        client.akId     = p.accessKeyId;
        client.sakId    = p.secretKey;
        client.region   = p.region;
        client.bucket   = p.bucket.length > 0
                        ? p.bucket
                        : currentBucket;
        return client;
    }

    string currentPath()
    {
        final switch (mode)
        {
            case S3PanelMode.Profiles:
                return "S3 Navigator";
            case S3PanelMode.Buckets:
                return currentProfile().name;
            case S3PanelMode.Objects:
                return currentProfile().name ~ "/" ~
                       currentBucket ~ "/" ~ currentPrefix;
        }
    }
}
// ──────────────────────────────────────────────────────────────
// Построить список бакетов
// ──────────────────────────────────────────────────────────────
void buildBucketItems(ref S3PanelState state, S3Bucket[] buckets)
{
    state.itemNames.length = buckets.length;
    state.items.length     = buckets.length;

    foreach (i, ref b; buckets)
    {
        state.itemNames[i] = b.name.to!wstring ~ '\0';

        memset(&state.items[i], 0, PluginPanelItem.sizeof);
        state.items[i].FileName       = state.itemNames[i].ptr;
        state.items[i].FileAttributes = FILE_ATTRIBUTE_DIRECTORY;
        state.items[i].FileSize       = 0;
    }
}

// ──────────────────────────────────────────────────────────────
// Построить список объектов внутри бакета
// ──────────────────────────────────────────────────────────────
void buildObjectItems(ref S3PanelState state, S3Object[] objects)
{
    state.itemNames.length = objects.length;
    state.items.length     = objects.length;

    foreach (i, ref obj; objects)
    {
        // Отображаемое имя = только последний сегмент ключа
        // "folder/sub/file.txt" → "file.txt"
        // "folder/sub/"         → "sub"  (папка без trailing slash)
        string displayName = obj.isDirectory
            ? lastSegment(stripTrailingSlash(obj.key))
            : lastSegment(obj.key);

        debugLog("  item[%d]: key=[%s] display=[%s] isDir=%s"
            .format(i, obj.key, displayName, obj.isDirectory));

        state.itemNames[i] = displayName.to!wstring ~ '\0';

        memset(&state.items[i], 0, PluginPanelItem.sizeof);
        state.items[i].FileName = state.itemNames[i].ptr;

        if (obj.isDirectory)
        {
            state.items[i].FileAttributes = FILE_ATTRIBUTE_DIRECTORY;
            state.items[i].FileSize       = 0;
        }
        else
        {
            state.items[i].FileAttributes = FILE_ATTRIBUTE_NORMAL;
            state.items[i].FileSize       = obj.size;
        }
    }
}

// ──────────────────────────────────────────────────────────────
// Навигация
// ──────────────────────────────────────────────────────────────
bool navigateInto(ref S3PanelState state, string dir)
{
    debugLog("navigateInto: dir=[" ~ dir ~ "]");
    debugLog("  before: bucket=[" ~ state.currentBucket ~
             "] prefix=[" ~ state.currentPrefix ~ "]");

    if (state.currentBucket.length == 0)
    {
        // Входим в бакет из корня
        state.currentBucket = dir;
        state.currentPrefix = "";
    }
    else
    {
        // Входим в "папку" внутри бакета
        // Важно: dir — это displayName ("sub"),
        // нам нужен полный префикс ("folder/sub/")
        state.currentPrefix = state.currentPrefix ~ dir ~ "/";
    }

    debugLog("  after:  bucket=[" ~ state.currentBucket ~
             "] prefix=[" ~ state.currentPrefix ~ "]");
    return true;
}

void navigateUp(ref S3PanelState state)
{
    if (state.currentPrefix.length == 0)
    {
        // Из корня бакета — в список бакетов
        // Запоминаем имя бакета для курсора
        state.pendingCursorName = state.currentBucket;
        state.currentBucket     = "";
        state.currentPrefix     = "";
    }
    else
    {
        // Убираем trailing slash
        auto prefix = state.currentPrefix;
        if (prefix.length > 0 && prefix[$-1] == '/')
            prefix = prefix[0 .. $-1];

        auto lastSlash = lastIndexOf(prefix, '/');

        if (lastSlash < 0)
        {
            // "subfolder" → корень бакета
            state.pendingCursorName = prefix;   // "subfolder"
            state.currentPrefix     = "";
        }
        else
        {
            // "folder/subfolder" → "folder/"
            state.pendingCursorName = prefix[lastSlash + 1 .. $];
            state.currentPrefix     = prefix[0 .. lastSlash + 1];
        }
    }

    debugLog("navigateUp: pendingCursor=[" ~
             state.pendingCursorName ~ "]" ~
             " bucket=[" ~ state.currentBucket ~ "]" ~
             " prefix=[" ~ state.currentPrefix ~ "]");
}

// ──────────────────────────────────────────────────────────────
// Вспомогательные функции путей
// ──────────────────────────────────────────────────────────────

// "a/b/c/" → "a/b/"
string parentPrefix(string prefix)
{
    import std.string : lastIndexOf;
    if (prefix.length == 0) return "";
    string p = prefix;
    if (p[$ - 1] == '/') p = p[0 .. $ - 1]; // убираем trailing /
    auto idx = p.lastIndexOf('/');
    if (idx < 0) return "";                   // были в корне бакета
    return p[0 .. idx + 1];
}

// "folder/sub/file.txt" → "file.txt"
// "folder/sub/"         → "sub/"
string lastSegment(string key)
{
    import std.string : lastIndexOf;
    if (key.length == 0) return key;
    // ищем последний / не считая trailing
    string k = key;
    if (k[$ - 1] == '/') k = k[0 .. $ - 1];
    auto idx = k.lastIndexOf('/');
    if (idx < 0) return key;
    return key[idx + 1 .. $];
}

// "folder/sub/" → "folder/sub"
string stripTrailingSlash(string s)
{
    if (s.length > 0 && s[$ - 1] == '/') return s[0 .. $ - 1];
    return s;
}

