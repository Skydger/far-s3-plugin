module plugin;

import conflict : ConflictChoice, showConflictDialog, formatBytes;
import farplugin;
import s3panel  : S3PanelState, S3PanelMode, navigateUp,
                  navigateInto,// buildProfileItems,
                  buildBucketItems, buildObjectItems;
import s3.client;
import config;
import s3log;
import s3config : loadSettings, saveSettings, settingsPath,
                  S3Settings, S3Profile;

import std.array;
import core.sys.windows.windows : HINSTANCE, BOOL, TRUE, FALSE,
                                   GUID, HANDLE, INVALID_HANDLE_VALUE,
                                   FILE_ATTRIBUTE_DIRECTORY,
                                   KEY_EVENT,
                                   SHIFT_PRESSED,
                                   LEFT_CTRL_PRESSED,
                                   RIGHT_CTRL_PRESSED,
                                   VK_F4, VK_F5, VK_F6, VK_F8, VK_F9, VK_DELETE;
import core.stdc.wchar_         : wcslen;
import core.stdc.string         : memset;
import std.conv                 : to;
import std.format               : format;

// GUIDs
immutable GUID c_PluginGuid = {
    0x5df10a10, 0x3748, 0x42e1,
    [0x96, 0xc6, 0xde, 0xf5, 0x48, 0xb4, 0x89, 0xde]
};
immutable GUID c_MenuGuid = {
    0xc13f2a53, 0x133d, 0x4ec0,
    [0xb5, 0x7c, 0x57, 0xc6, 0xdc, 0xf6, 0xcb, 0x0c]
};
immutable GUID c_DialogGuid = {
    0x565088dd, 0x2066, 0x48ad,
    [0xab, 0x32, 0x1d, 0x0b, 0x8d, 0x31, 0xe1, 0xe5]
};

private enum ProfDlg : int
{
    Frame       = 0,
    LblName     = 1,  TxtName     = 2,
    LblEndpoint = 3,  TxtEndpoint = 4,
    LblBucket   = 5,  TxtBucket   = 6,
    LblKey      = 7,  TxtKey      = 8,
    LblSecret   = 9,  TxtSecret   = 10,
    LblRegion   = 11, TxtRegion   = 12,
    Sep         = 13,
    BtnOk       = 14,
    BtnCancel   = 15,
    Count       = 16,
}

__gshared PluginStartupInfo    g_Info;
__gshared FarStandardFunctions g_FSF;
__gshared S3Settings g_settings;

extern(Windows)
BOOL DllMain(HINSTANCE hinstDLL, uint fdwReason, void* lpvReserved)
{
    return TRUE;
}

extern(Windows) export:

void GetGlobalInfoW(GlobalInfo* info)
{
    info.StructSize    = GlobalInfo.sizeof;
    info.MinFarVersion = MakeFarVersion(3, 0, 0, 0, VERSION_STAGE.VS_RELEASE);
    info.Version       = MakeFarVersion(0, 1, 0, 0, VERSION_STAGE.VS_ALPHA);
    info.Guid          = c_PluginGuid;
    info.Title         = "S3 Navigator\0"w.ptr;
    info.Description   = "Browse S3-compatible storage (AWS, MinIO, etc)\0"w.ptr;
    info.Author        = "Skydger\0"w.ptr;
}

void SetStartupInfoW(PluginStartupInfo* info)
{
    g_Info     = *info;
    g_FSF      = *info.FSF;
    g_Info.FSF = &g_FSF;

    import s3log : initLog;
    initLog();

    // Загружаем профили
    g_settings = loadSettings(settingsPath());
    debugLog("SetStartupInfoW: loaded " ~
             g_settings.profiles.length.to!string ~
             " profiles");
}

void GetPluginInfoW(PluginInfo* info)
{
    info.StructSize = PluginInfo.sizeof;
    info.Flags      = PF_NONE;

    // ── Меню плагинов (F11) ───────────────────────────────
    static immutable wchar* s_MenuLabel = "S3 Navigator\0"w.ptr;
    static immutable GUID   s_MenuGuid  = c_MenuGuid;
    info.PluginMenu.Guids   = &s_MenuGuid;
    info.PluginMenu.Strings = &s_MenuLabel;
    info.PluginMenu.Count   = 1;

    // ── Меню дисков (Alt+F1 / Alt+F2) ────────────────────
    static immutable wchar* s_DiskLabel = "S3 Navigator\0"w.ptr;
    static immutable GUID   s_DiskGuid  = c_MenuGuid;  // можно отдельный GUID
    info.DiskMenu.Guids   = &s_DiskGuid;
    info.DiskMenu.Strings = &s_DiskLabel;
    info.DiskMenu.Count   = 1;

    // ── Меню конфигурации (F9) ────────────────────────────
    static immutable wchar* s_CfgLabel = "S3 Navigator Settings\0"w.ptr;
    static immutable GUID   s_CfgGuid  = c_DialogGuid;
    info.PluginConfig.Guids   = &s_CfgGuid;
    info.PluginConfig.Strings = &s_CfgLabel;
    info.PluginConfig.Count   = 1;
}

HANDLE OpenW(OpenInfo* info)
{
    auto state      = new S3PanelState();
    state.settings  = &g_settings;   // глобальный конфиг загружен в SetStartupInfoW

    // Если профилей нет — предлагаем создать
    if (g_settings.profiles.length == 0)
    {
        debugLog("OpenW: no profiles configured");
        // Можно сразу открыть диалог добавления профиля
        // Пока просто открываем панель — она покажет пустой список
    }

    debugLog("OpenW: opening S3 Navigator, profiles=" ~
             g_settings.profiles.length.to!string);

    return cast(HANDLE) state;
}

BOOL ConfigureW(ConfigureInfo* info)
{
    auto cfg = loadConfig(g_Info, c_PluginGuid);
    if (showConfigDialog(g_Info, c_PluginGuid, c_DialogGuid, cfg))
    {
        saveConfig(g_Info, c_PluginGuid, cfg);
        return TRUE;
    }
    return FALSE;
}

// src/plugin.d — GetOpenPanelInfoW
void GetOpenPanelInfoW(OpenPanelInfo* info)
{
    auto state = cast(S3PanelState*) info.hPanel;
    if (state is null) return;

    info.StructSize = OpenPanelInfo.sizeof;
    info.Flags      = OPIF_USEATTRHIGHLIGHTING | OPIF_ADDDOTS;
    info.Format     = "S3 Navigator\0"w.ptr;

    static wchar[1024] s_Title;
    auto path = ("[S3] " ~ state.currentPath()).to!wstring ~ '\0';
    size_t n  = path.length < s_Title.length
                ? path.length : s_Title.length;
    s_Title[0 .. n] = path[0 .. n];
    info.PanelTitle = s_Title.ptr;

    static wchar[1024] s_CurDir;
    auto cd = state.currentPath().to!wstring ~ '\0';
    n = cd.length < s_CurDir.length ? cd.length : s_CurDir.length;
    s_CurDir[0 .. n] = cd[0 .. n];
    info.CurDir = s_CurDir.ptr;

    // ── Устанавливаем курсор если есть ожидающий индекс ──
    if (state.pendingCursorIndex >= 0)
    {
        debugLog("GetOpenPanelInfoW: setting cursor to index=" ~
                 state.pendingCursorIndex.to!string);

        // Запускаем SYNCHRO — к этому моменту панель
        // уже получила данные из GetFindDataW
        g_pendingCursorState = state;
        g_Info.AdvControl(
            &c_PluginGuid,
            ADVANCED_CONTROL_COMMANDS.ACTL_SYNCHRO,
            0, null);

        state.pendingCursorIndex = -1;
    }

    // KeyBar
    if (state.mode == S3PanelMode.Profiles)
    {
        static KeyBarLabel[6] s_kbLabels;
        static KeyBarTitles   s_kb;

        s_kbLabels[0].Key.VirtualKeyCode  = VK_F4;
        s_kbLabels[0].Key.ControlKeyState = 0;
        s_kbLabels[0].Text     = "Edit\0"w.ptr;
        s_kbLabels[0].LongText = "Edit connection\0"w.ptr;

        s_kbLabels[1].Key.VirtualKeyCode  = VK_F4;
        s_kbLabels[1].Key.ControlKeyState = SHIFT_PRESSED;
        s_kbLabels[1].Text     = "NewSes\0"w.ptr;
        s_kbLabels[1].LongText = "New session\0"w.ptr;

        s_kbLabels[2].Key.VirtualKeyCode  = VK_F5;
        s_kbLabels[2].Key.ControlKeyState = SHIFT_PRESSED;
        s_kbLabels[2].Text     = "Duplic\0"w.ptr;
        s_kbLabels[2].LongText = "Duplicate session\0"w.ptr;

        s_kbLabels[3].Key.VirtualKeyCode  = VK_F6;
        s_kbLabels[3].Key.ControlKeyState = SHIFT_PRESSED;
        s_kbLabels[3].Text     = "Rename\0"w.ptr;
        s_kbLabels[3].LongText = "Rename session\0"w.ptr;

        s_kbLabels[4].Key.VirtualKeyCode  = VK_F8;
        s_kbLabels[4].Key.ControlKeyState = 0;
        s_kbLabels[4].Text     = "Delete\0"w.ptr;
        s_kbLabels[4].LongText = "Delete session\0"w.ptr;

        s_kbLabels[5].Key.VirtualKeyCode  = VK_F9;
        s_kbLabels[5].Key.ControlKeyState = SHIFT_PRESSED;
        s_kbLabels[5].Text     = "Save\0"w.ptr;
        s_kbLabels[5].LongText = "Save settings\0"w.ptr;

        s_kb.CountLabels = 6;
        s_kb.Labels      = s_kbLabels.ptr;
        info.KeyBar      = &s_kb;
    }
    else
    {
        info.KeyBar = null;
    }
}

// Глобальный указатель для SYNCHRO
__gshared S3PanelState* g_pendingCursorState;

extern(Windows) export
void SynchroEventW(void* param)
{
    debugLog("SynchroEventW: entered");

    auto state = g_pendingCursorState;
    if (state is null)
    {
        debugLog("SynchroEventW: state is null");
        return;
    }

    // Используем сохранённый индекс — не ищем по имени
    int idx = state.pendingCursorIndex;

    // pendingCursorIndex уже сброшен в GetOpenPanelInfoW
    // но на случай если вызван из другого места:
    if (idx < 0)
    {
        debugLog("SynchroEventW: no pending cursor");
        g_pendingCursorState = null;
        return;
    }

    debugLog("SynchroEventW: setting cursor to idx=" ~
             idx.to!string);

    PanelRedrawInfo pri;
    pri.StructSize   = PanelRedrawInfo.sizeof;
    pri.CurrentItem  = idx;
    pri.TopPanelItem = idx > 3 ? idx - 3 : 0;

    g_Info.PanelControl(
        cast(HANDLE) state,
        FILE_CONTROL_COMMANDS.FCTL_REDRAWPANEL,
        0, &pri);

    debugLog("SynchroEventW: done");
    g_pendingCursorState     = null;
    state.pendingCursorIndex = -1;
}

BOOL SetDirectoryW(SetDirectoryInfo* info)
{
    auto state = cast(S3PanelState*) info.hPanel;
    if (state is null) return FALSE;

    try
    {
        auto dir = info.Dir[0 .. wcslen(info.Dir)].to!string;
        debugLog("SetDirectoryW: mode=" ~
                 state.mode.to!string ~ " dir=[" ~ dir ~ "]");

        if (dir == "..")
        {
            final switch (state.mode)
            {
                case S3PanelMode.Profiles:
                    break;

                case S3PanelMode.Buckets:
                    state.pendingCursorName =
                        state.currentProfile().name;
                    state.profileIndex  = -1;
                    state.currentBucket = "";
                    state.mode          = S3PanelMode.Profiles;
                    break;

                case S3PanelMode.Objects:
                    navigateUp(*state);
                    break;
            }
        }
        else
        {
            state.pendingCursorName = "";

            final switch (state.mode)
            {
                case S3PanelMode.Profiles:
                    foreach (idx, ref p;
                             state.settings.profiles)
                    {
                        if (p.name == dir)
                        {
                            state.profileIndex  = cast(int) idx;
                            state.currentBucket = p.bucket;
                            state.currentPrefix = "";
                            state.mode = p.bucket.length > 0
                                ? S3PanelMode.Objects
                                : S3PanelMode.Buckets;
                            break;
                        }
                    }
                    break;

                case S3PanelMode.Buckets:
                    state.currentBucket = dir;
                    state.currentPrefix = "";
                    state.mode          = S3PanelMode.Objects;
                    break;

                case S3PanelMode.Objects:
                    navigateInto(*state, dir);
                    break;
            }
        }

        debugLog("SetDirectoryW: → mode=" ~
                 state.mode.to!string ~
                 " bucket=[" ~ state.currentBucket ~ "]" ~
                 " prefix=[" ~ state.currentPrefix ~ "]");
    }
    catch (Throwable e)
    {
        debugLog("SetDirectoryW error: " ~ e.msg);
        showErrorStr("Navigation error:\n" ~ e.msg);
        return FALSE;
    }

    debugLog("SetDirectoryW: pendingCursorName=[" ~
             state.pendingCursorName ~ "] before SYNCHRO check");

    // if (state.pendingCursorName.length > 0)
    // {
    //     g_pendingCursorState = state;
    //     g_Info.AdvControl(
    //         &c_PluginGuid,
    //         ADVANCED_CONTROL_COMMANDS.ACTL_SYNCHRO,
    //         0,
    //         null);
    //     debugLog("SetDirectoryW: SYNCHRO scheduled for [" ~
    //              state.pendingCursorName ~ "]");
    // }
    // else
    // {
    //     debugLog("SetDirectoryW: pendingCursorName is empty, no SYNCHRO");
    // }
    return TRUE;
}

// // FAR вызывает SynchroEventW из главного потока
// extern(Windows) export
// void SynchroEventW(void* param)
// {
//     auto state = g_pendingCursorState;
//     if (state is null || state.pendingCursorName.length == 0)
//         return;

//     debugLog("SynchroEventW: setting cursor to [" ~
//              state.pendingCursorName ~ "]");

//     // Ищем индекс элемента по имени в текущем списке
//     PanelInfo pi;
//     pi.StructSize = PanelInfo.sizeof;

//     if (g_Info.PanelControl(
//             cast(HANDLE) state,
//             FILE_CONTROL_COMMANDS.FCTL_GETPANELINFO,
//             0,
//             &pi) == 0)
//     {
//         debugLog("SynchroEventW: FCTL_GETPANELINFO failed");
//         state.pendingCursorName = "";
//         g_pendingCursorState    = null;
//         return;
//     }

//     // Перебираем элементы панели — ищем нужное имя
//     foreach (i; 0 .. pi.ItemsNumber)
//     {
//         // Получаем элемент
//         intptr_t sz = g_Info.PanelControl(
//             cast(HANDLE) state,
//             FILE_CONTROL_COMMANDS.FCTL_GETPANELITEM,
//             cast(intptr_t) i,
//             null);

//         if (sz == 0) continue;

//         auto buf = new ubyte[sz];
//         auto fpi = cast(PluginPanelItem*) buf.ptr;
//         fpi.StructSize = sz;

//         g_Info.PanelControl(
//             cast(HANDLE) state,
//             FILE_CONTROL_COMMANDS.FCTL_GETPANELITEM,
//             cast(intptr_t) i,
//             fpi);

//         auto name = fpi.FileName[0 .. wcslen(fpi.FileName)].to!string;

//         if (name == state.pendingCursorName)
//         {
//             // Нашли — устанавливаем курсор
//             PanelRedrawInfo pri;
//             pri.StructSize   = PanelRedrawInfo.sizeof;
//             pri.CurrentItem  = i;
//             pri.TopPanelItem = i > 5 ? i - 5 : 0; // немного выше курсора

//             g_Info.PanelControl(
//                 cast(HANDLE) state,
//                 FILE_CONTROL_COMMANDS.FCTL_REDRAWPANEL,
//                 0,
//                 &pri);

//             debugLog("SynchroEventW: cursor set to item " ~
//                      i.to!string ~ " [" ~ name ~ "]");
//             break;
//         }
//     }

//     state.pendingCursorName = "";
//     g_pendingCursorState    = null;
// }

void FreeFindDataW(FreeFindDataInfo* info) { }


BOOL GetFilesW(GetFilesInfo* info)
{
    auto state = cast(S3PanelState*) info.hPanel;
    if (state is null) return FALSE;

    auto destPath = info.DestPath[0 .. wcslen(info.DestPath)].to!string;

    debugLog("GetFilesW: items=" ~ info.ItemsNumber.to!string ~
             " dest=" ~ destPath);

    S3Client client;
    try { client = state.makeClient(); }
    catch (Throwable e)
    {
        showErrorStr("S3 connection error:\n" ~ e.msg);
        return FALSE;
    }

    // ── Собираем полный список файлов для скачивания ──────
    // Для папок — рекурсивно разворачиваем через listObjectsRecursive
    struct DownloadTask
    {
        string s3Key;
        string localPath;
        ulong  size;
        string folderName;
        bool   appendMode = false;
    }

    DownloadTask[] tasks;
    bool           isFolder = false;
    string         folderTitle;

    try
    {
        foreach (i; 0 .. info.ItemsNumber)
        {
            auto item     = &info.PanelItem[i];
            auto itemName = item.FileName[0 .. wcslen(item.FileName)]
                            .to!string;

            if (item.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            {
                // ── Папка: разворачиваем рекурсивно ───────
                isFolder    = true;
                folderTitle = itemName;

                string s3Prefix  = state.currentPrefix ~ itemName ~ "/";
                string localBase = destPath ~ "\\" ~ itemName;

                debugLog("GetFilesW: expanding folder " ~ s3Prefix);

                auto objects = client.listObjectsRecursive(s3Prefix);
                foreach (ref obj; objects)
                {
                    if (obj.isDirectory) continue;

                    // Локальный путь: сохраняем структуру подпапок
                    // obj.key = "prefix/sub/file.txt"
                    // нам нужно: localBase + "\sub\file.txt"
                    string relPath = obj.key[s3Prefix.length .. $]
                                     .replace("/", "\\");
                    tasks ~= DownloadTask(
                        obj.key,
                        localBase ~ "\\" ~ relPath,
                        obj.size,
                        itemName);
                }
            }
            else
            {
                // ── Файл: добавляем напрямую ───────────────
                string s3Key    = state.currentPrefix ~ itemName;
                string localPth = destPath ~ "\\" ~ itemName;
                tasks ~= DownloadTask(
                    s3Key,
                    localPth,
                    cast(ulong) item.FileSize,
                    "");
            }
        }
    }
    catch (Throwable e)
    {
        showErrorStr("S3 listing error:\n" ~ e.msg);
        return FALSE;
    }

    if (tasks.length == 0) return TRUE;

    debugLog("GetFilesW: total tasks=" ~ tasks.length.to!string);

    // ── Определяем заголовок прогрессбара ─────────────────
    string progressTitle = isFolder
        ? "Copying folder: " ~ folderTitle
        : "Downloading from S3";

    // ── Глобальный флаг "запомнить выбор при конфликтах" ──
    ConflictChoice rememberChoice  = ConflictChoice.Ask;
    bool           rememberForAll  = false;

    size_t current = 0;
    size_t failed  = 0;
    foreach (ref task; tasks)
    {
        scope(exit) current++;

        showProgress(progressTitle, task.s3Key,
                    current, tasks.length, 0, task.size);

        import std.file : exists;

        // ── Проверяем конфликт через HEAD ─────────────────────
        if (exists(task.localPath) && !(info.OpMode & OPM_SILENT))
        {
            ConflictChoice choice;

            if (rememberForAll && rememberChoice != ConflictChoice.Ask)
            {
                choice = rememberChoice;
            }
            else
            {
                // HEAD запрос — получаем метаданные без скачивания
                string checksum;
                ulong  remoteSize = task.size;
                try
                {
                    auto meta  = client.headObject(task.s3Key);
                    checksum   = meta.checksumCRC32.length > 0
                                ? "CRC32: " ~ meta.checksumCRC32
                                : "MD5: "   ~ meta.etag;
                    remoteSize = meta.size > 0 ? meta.size : task.size;
                }
                catch (Exception e)
                {
                    debugLog("HEAD failed, using task.size: " ~ e.msg);
                    checksum = "";
                }

                bool remember = false;
                choice = showConflictDialog(
                    g_Info,
                    c_PluginGuid,
                    c_DialogGuid,
                    task.localPath,
                    remoteSize,
                    checksum,     // ← строка вместо буфера
                    remember);

                if (remember)
                {
                    rememberForAll = true;
                    rememberChoice = choice;
                }
            }

            final switch (choice)
            {
                case ConflictChoice.Overwrite: break;
                case ConflictChoice.Skip:
                    debugLog("  Skipped");
                    continue;
                case ConflictChoice.Rename:
                    task.localPath = makeUniquePath(task.localPath);
                    break;
                case ConflictChoice.Append:
                    task.appendMode = true;
                    break;
                case ConflictChoice.Cancel:
                    hideProgress();
                    return FALSE;
                case ConflictChoice.Ask:
                    break;
            }
        }

        // ── Скачиваем только если пользователь согласился ─────
        try
        {
            import std.file : append, write, mkdirRecurse;
            import std.path : dirName;

            immutable size_t capIdx   = current;
            immutable size_t capTotal = tasks.length;
            immutable string capTitle = progressTitle;
            immutable string capKey   = task.s3Key;
            immutable ulong  capSize  = task.size;

            if (task.appendMode)
            {
                auto body = client.downloadToMemory(task.s3Key);
                mkdirRecurse(dirName(task.localPath));
                append(task.localPath, body);
                debugLog("  Appended OK");
            }
            else
            {
                string etag = client.downloadFileWithETag(
                    task.s3Key,
                    task.localPath,
                    (ulong recv, ulong total) {
                        showProgress(capTitle, capKey,
                                    capIdx, capTotal,
                                    recv, total > 0 ? total : capSize);
                    });
                debugLog("  OK etag=" ~ etag);
            }
        }
        catch (Throwable e)
        {
            debugLog("  FAILED: " ~ e.msg);
            failed++;
            if (!(info.OpMode & OPM_SILENT))
                showErrorStr("Download failed: " ~ task.s3Key ~
                            "\n" ~ e.msg);
        }
    }


    hideProgress();

    return (failed == 0) ? TRUE : FALSE;
}

// src/plugin.d — GetFindDataW

BOOL GetFindDataW(GetFindDataInfo* info)
{
    auto state = cast(S3PanelState*) info.hPanel;
    if (state is null) return FALSE;

    try
    {
        final switch (state.mode)
        {
            case S3PanelMode.Profiles:
                buildProfileItems(*state);
                break;

            case S3PanelMode.Buckets:
                if (state.profileIndex < 0 ||
                    state.profileIndex >=
                    cast(int) state.settings.profiles.length)
                {
                    state.items.length     = 0;
                    state.itemNames.length = 0;
                    break;
                }
                auto client  = state.makeClient();
                auto buckets = client.listBuckets();
                buildBucketItems(*state, buckets);
                break;

            case S3PanelMode.Objects:
                if (state.profileIndex < 0 ||
                    state.profileIndex >=
                    cast(int) state.settings.profiles.length)
                {
                    state.items.length     = 0;
                    state.itemNames.length = 0;
                    break;
                }
                auto client2  = state.makeClient();
                auto objects  = client2.listObjectsV2(
                    state.currentPrefix, "/");
                buildObjectItems(*state, objects);
                break;
        }
    }
    catch (Throwable e)
    {
        debugLog("GetFindDataW error: " ~ e.msg);
        showErrorStr("S3 Error:\n" ~ e.msg);
        state.items.length     = 0;
        state.itemNames.length = 0;
    }

    info.PanelItem   = state.items.ptr;
    info.ItemsNumber = state.items.length;

    // ── Устанавливаем курсор ЗДЕСЬ пока данные свежие ────
    // FAR ещё не перерисовал панель, но мы знаем индекс
    if (state.pendingCursorName.length > 0)
    {
        debugLog("GetFindDataW: looking for cursor [" ~
                 state.pendingCursorName ~ "] in " ~
                 state.items.length.to!string ~ " items");

        foreach (i, ref item; state.items)
        {
            if (item.FileName is null) continue;

            size_t fnLen = 0;
            while (item.FileName[fnLen] != '\0') fnLen++;
            auto name = item.FileName[0 .. fnLen].to!string;

            if (name == state.pendingCursorName)
            {
                // Сохраняем индекс — передадим в FreeFindDataW
                // или через отдельное поле
                state.pendingCursorIndex = cast(int) i;
                debugLog("GetFindDataW: cursor index=" ~
                         i.to!string ~ " [" ~ name ~ "]");
                break;
            }
        }

        state.pendingCursorName = "";
    }

    return TRUE;
}

// Строим список профилей
// Строим список профилей
private void buildProfileItems(ref S3PanelState state)
{
    state.items.length     = 0;
    state.itemNames.length = 0;

    if (state.settings is null ||
        state.settings.profiles.length == 0)
    {
        debugLog("buildProfileItems: no profiles configured");
        return;
    }

    foreach (ref profile; state.settings.profiles)
    {
        state.itemNames ~= profile.name.to!wstring ~ '\0';

        PluginPanelItem item;
        // Отображаем профили как папки
        item.FileAttributes = FILE_ATTRIBUTE_DIRECTORY;
        item.FileName       = state.itemNames[$-1].ptr;
        state.items ~= item;
    }

    debugLog("buildProfileItems: " ~
             state.items.length.to!string ~ " profiles");
}

// "file.txt" → "file (2).txt", "file (3).txt" и т.д.
private string makeUniquePath(string path)
{
    import std.file  : exists;
    import std.path  : extension, stripExtension;

    if (!exists(path)) return path;

    string base = stripExtension(path);
    string ext  = extension(path);     // ".txt" или ""

    foreach (n; 2 .. 1000)
    {
        string candidate = "%s (%d)%s".format(base, n, ext);
        if (!exists(candidate)) return candidate;
    }

    // Крайний случай — добавляем timestamp
    import std.datetime : Clock;
    return "%s_%d%s".format(base, Clock.currTime().toUnixTime(), ext);
}

void ClosePanelW(ClosePanelInfo* info)
{
    auto state = cast(S3PanelState*) info.hPanel;
    if (state) destroy(*state);
}

// ──────────────────────────────────────────────────────────────
// Прогрессбар
// ──────────────────────────────────────────────────────────────

// Буферы живут всё время работы прогрессбара —
// FAR держит указатели на них пока отображает Message
// Буферы для прогрессбара
// Ширина полосок прогресса в символах
private enum BAR_WIDTH = 40;

// Буферы строк — живут всё время показа диалога
__gshared wchar[128] g_pLine1;  // "File N of M"
__gshared wchar[128] g_pLine2;  // имя файла
__gshared wchar[128] g_pLine3;  // "12.3 MB / 45.6 MB"
__gshared wchar[128] g_pLine4;  // полоска файла + %
__gshared wchar[4]   g_pSep;    // пустая строка-разделитель
__gshared wchar[128] g_pLine5;  // "Total progress"
__gshared wchar[128] g_pLine6;  // полоска общего + %

private void showProgress(
    string progressTitle,  // "Downloading from S3" или "Copying folder: X"
    string currentFile,    // s3Key текущего файла
    size_t fileIndex,      // 0-based
    size_t totalFiles,
    ulong  bytesReceived,
    ulong  bytesTotal)
{
    // Процент для заголовка — общий прогресс
    int overallPct = (totalFiles > 0)
        ? cast(int)(
            (fileIndex * 100 +
             (bytesTotal > 0
              ? cast(int)((bytesReceived * 100) / bytesTotal)
              : 0))
            / totalFiles)
        : 0;

    // ── Заголовок с процентами (рамка Message) ────────────
    wstring title = "{" ~ overallPct.to!wstring ~ "%} " ~
                    progressTitle.to!wstring ~ "\0"w;
    static wchar[256] s_title;
    fillBufW(s_title, title);

    // ── Строка 1: "File N of M" ───────────────────────────
    fillBufW(g_pLine1,
        "File "w ~ (fileIndex + 1).to!wstring ~
        " of "w  ~ totalFiles.to!wstring);

    // ── Строка 2: имя файла ───────────────────────────────
    {
        auto fn = currentFile.to!wstring;
        if (fn.length > BAR_WIDTH + 2)
            fn = "..."w ~ fn[fn.length - (BAR_WIDTH - 1) .. $];
        fillBufW(g_pLine2, fn);
    }

    // ── Строка 3: размеры ─────────────────────────────────
    if (bytesTotal > 0)
        fillBufW(g_pLine3,
            formatBytes(bytesReceived) ~ " / "w ~
            formatBytes(bytesTotal));
    else if (bytesReceived > 0)
        fillBufW(g_pLine3, formatBytes(bytesReceived));
    else
        fillBufW(g_pLine3, " "w);

    // ── Строка 4: полоска файла ───────────────────────────
    int filePct = (bytesTotal > 0)
                  ? cast(int)((bytesReceived * 100) / bytesTotal)
                  : 0;
    fillBufW(g_pLine4, makeBar(filePct, BAR_WIDTH));

    // ── Разделитель ───────────────────────────────────────
    fillBufW(g_pSep, " "w);

    // ── Строка 5: заголовок общего прогресса ─────────────
    fillBufW(g_pLine5, "Total progress:"w);

    // ── Строка 6: полоска общего прогресса ───────────────
    fillBufW(g_pLine6, makeBar(overallPct, BAR_WIDTH));

    const(wchar)*[8] lines = [
        s_title.ptr,   // заголовок = рамка
        g_pLine1.ptr,
        g_pLine2.ptr,
        g_pLine3.ptr,
        g_pLine4.ptr,
        g_pSep.ptr,
        g_pLine5.ptr,
        g_pLine6.ptr,
    ];

    g_Info.Message(
        &c_PluginGuid,
        &c_PluginGuid,
        FMSG_LEFTALIGN,  // без KEEPBACKGROUND — даёт рамку
        null,
        lines.ptr,
        lines.length,
        0);

    // Таскбар
    g_Info.AdvControl(
        &c_PluginGuid,
        ADVANCED_CONTROL_COMMANDS.ACTL_SETPROGRESSSTATE,
        cast(ptrdiff_t) TASKBARPROGRESSTATE.TBPS_NORMAL,
        null);

    ProgressValue pv;
    pv.StructSize = ProgressValue.sizeof;
    pv.Completed  = cast(ulong) overallPct;
    pv.Total      = 100UL;

    g_Info.AdvControl(
        &c_PluginGuid,
        ADVANCED_CONTROL_COMMANDS.ACTL_SETPROGRESSVALUE,
        0,
        &pv);
}

// ── Нарисовать полоску прогресса ──────────────────────────────
// Результат: "████████████░░░░░░░░ 42%"
// Используем:
//   U+2588 █  FULL BLOCK       — заполненная часть
//   U+2592 ▒  MEDIUM SHADE     — пустая часть (как в FAR)
private wstring makeBar(int pct, int width)
{
    if (pct < 0)   pct = 0;
    if (pct > 100) pct = 100;

    int filled = (pct * width) / 100;

    wstring bar;
    foreach (i; 0 .. width)
        bar ~= (i < filled) ? '\u2588' : '\u2592';

    bar ~= " "w ~ pct.to!wstring ~ "%"w;
    return bar;
}

// ── Заполнить wchar[] буфер из wstring ────────────────────────
private void fillBufW(ref wchar[] buf, wstring s)
{
    size_t n = s.length < buf.length - 1
               ? s.length : buf.length - 1;
    buf[0 .. n] = s[0 .. n];
    buf[n] = '\0';
}

// Перегрузка для статических массивов
private void fillBufW(size_t N)(ref wchar[N] buf, wstring s)
{
    size_t n = s.length < N - 1 ? s.length : N - 1;
    buf[0 .. n] = s[0 .. n];
    buf[n] = '\0';
}

// ── Форматирование размера ─────────────────────────────────────
// private wstring formatBytes(ulong bytes)
// {
//     import std.format : format;
//     if (bytes < 1024)
//         return bytes.to!wstring ~ " B"w;
//     else if (bytes < 1024 * 1024)
//         return "%.1f KB"w.format(bytes / 1024.0).to!wstring;
//     else if (bytes < 1024UL * 1024 * 1024)
//         return "%.1f MB"w.format(
//             bytes / (1024.0 * 1024)).to!wstring;
//     else
//         return "%.2f GB"w.format(
//             bytes / (1024.0 * 1024 * 1024)).to!wstring;
// }


private void hideProgress()
{
    g_Info.AdvControl(
        &c_PluginGuid,
        ADVANCED_CONTROL_COMMANDS.ACTL_SETPROGRESSSTATE,
        cast(ptrdiff_t) TASKBARPROGRESSTATE.TBPS_NOPROGRESS,
        null);

    g_Info.AdvControl(
        &c_PluginGuid,
        ADVANCED_CONTROL_COMMANDS.ACTL_REDRAWALL,
        0,
        null);
}

// ──────────────────────────────────────────────────────────────
// Сообщение об ошибке
// ──────────────────────────────────────────────────────────────
// Перегрузка для string — конвертируем автоматически
private void showErrorStr(string message)
{
    showError(message.to!wstring);
}

// Основная версия для wstring
private void showError(wstring message)
{
    static wchar[1024] s_msg;

    // Добавляем null-терминатор
    wstring safeMsg = message ~ '\0';
    size_t n = safeMsg.length < s_msg.length
               ? safeMsg.length : s_msg.length - 1;
    s_msg[0 .. n] = safeMsg[0 .. n];
    s_msg[n] = '\0';

    const(wchar)*[2] lines = [
        "S3 Navigator\0"w.ptr,
        s_msg.ptr,
    ];

    g_Info.Message(
        &c_PluginGuid,
        &c_PluginGuid,
        FMSG_WARNING | FMSG_MB_OK,  // ← красное окно с кнопкой OK
        null,
        lines.ptr,
        lines.length,
        1   // 1 кнопка OK
    );
}

enum ConflictChoice
{
    Ask,        // ещё не решено
    Overwrite,  // перезаписать
    Skip,       // пропустить
    Cancel,     // отменить всё
}

// Буферы для диалога конфликтов
__gshared wchar[512] g_cfPath;
__gshared wchar[128] g_cfNew;
__gshared wchar[128] g_cfExisting;

private ConflictChoice showConflictDialog(
    string localPath,
    ulong  newSize,
    ulong  existingSize,
    ref bool rememberChoice)
{
    import std.format : format;

    // ── Строка с путём ────────────────────────────────────
    fillBufW(g_cfPath, localPath.to!wstring);

    // ── Строки размеров ───────────────────────────────────
    fillBufW(g_cfNew,
        "New      "w ~ formatBytes(newSize));
    fillBufW(g_cfExisting,
        "Existing "w ~ formatBytes(existingSize));

    // ── Диалог через Message с кнопками ───────────────────
    // Кнопки: Overwrite=0, Skip=1, Cancel=2
    const(wchar)*[6] lines = [
        "File already exists\0"w.ptr,   // заголовок (рамка)
        g_cfPath.ptr,
        g_cfNew.ptr,
        g_cfExisting.ptr,
        " \0"w.ptr,                      // разделитель
        "Overwrite\0"w.ptr,              // тут кнопки не работают через lines
    ];

    // Message с кнопками — передаём кнопки как последние N строк,
    // указываем их количество последним параметром
    auto dlgLines = [
        "Warning\0"w.ptr,               // заголовок
        "File already exists\0"w.ptr,
        g_cfPath.ptr,
        g_cfNew.ptr,
        g_cfExisting.ptr,
        " \0"w.ptr,
        // Кнопки передаём отдельным массивом ниже
    ];

    // FAR Message API: последние `buttonsCount` строк = кнопки
    // Поэтому добавляем кнопки в конец массива строк
    auto allLines = [
        "Warning\0"w.ptr,               // [0] заголовок
        "File already exists\0"w.ptr,   // [1]
        g_cfPath.ptr,                   // [2] путь
        g_cfNew.ptr,                    // [3] новый файл
        g_cfExisting.ptr,               // [4] существующий
        " \0"w.ptr,                     // [5] разделитель
        "Overwrite\0"w.ptr,             // [6] кнопка 0
        "Skip\0"w.ptr,                  // [7] кнопка 1
        "Cancel\0"w.ptr,                // [8] кнопка 2
    ];

    int result = cast(int) g_Info.Message(
        &c_PluginGuid,
        &c_PluginGuid,
        FMSG_WARNING,
        null,
        allLines.ptr,
        allLines.length,  // ← автоматически правильное число
        3);               // 3 кнопки

    // result: 0=Overwrite, 1=Skip, 2=Cancel, -1=Escape
    rememberChoice = false; // TODO: добавить чекбокс "Remember"

    switch (result)
    {
        case 0:  return ConflictChoice.Overwrite;
        case 1:  return ConflictChoice.Skip;
        default: return ConflictChoice.Cancel;
    }
}

BOOL ProcessPanelInputW(ProcessPanelInputInfo* info)
{
    auto state = cast(S3PanelState*) info.hPanel;
    if (state is null) return FALSE;

    if (state.mode != S3PanelMode.Profiles) return FALSE;

    // KEY_EVENT = 1 из Windows API
    if (info.Rec.EventType != KEY_EVENT) return FALSE;

    auto key = &info.Rec.Event.KeyEvent;
    if (!key.bKeyDown) return FALSE;

    immutable bool shift =
        (key.dwControlKeyState & SHIFT_PRESSED) != 0;
    immutable bool ctrl  =
        (key.dwControlKeyState &
         (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;

    switch (key.wVirtualKeyCode)
    {
        case VK_F4:
            if (shift) { createNewProfile(*state);  return TRUE; }
            else       { editCurrentProfile(*state); return TRUE; }

        case VK_F5:
            if (shift) { duplicateCurrentProfile(*state); return TRUE; }
            return FALSE;

        case VK_F6:
            if (shift) { renameCurrentProfile(*state); return TRUE; }
            return FALSE;

        case VK_F8:
            // F8 — Delete (перехватываем чтобы FAR не делал своё)
            deleteCurrentProfile(*state);
            return TRUE;

        case VK_F9:
            if (shift)
            {
                // Shift+F9 — Save
                saveSettings(settingsPath(), *state.settings);
                debugLog("ProcessPanelInputW: settings saved manually");
                return TRUE;
            }
            return FALSE;

        case VK_DELETE:
            deleteCurrentProfile(*state);
            return TRUE;

        default:
            return FALSE;
    }
}

// Редактировать профиль (новый или существующий)
private bool showProfileDialog(ref S3Profile profile,
                                bool isNew)
{
    import core.stdc.string : memset;

    enum W = 70;

    // Буферы для полей ввода
    static wchar[256] s_name;
    static wchar[256] s_endpoint;
    static wchar[256] s_bucket;
    static wchar[256] s_key;
    static wchar[256] s_secret;
    static wchar[64]  s_region;

    // Заполняем текущими значениями
    void fillBuf(size_t N)(ref wchar[N] buf, string s)
    {
        auto ws = s.to!wstring;
        size_t n = ws.length < N-1 ? ws.length : N-1;
        buf[0 .. n] = ws[0 .. n];
        buf[n] = '\0';
    }

    fillBuf(s_name,     profile.name);
    fillBuf(s_endpoint, profile.endpoint);
    fillBuf(s_bucket,   profile.bucket);
    fillBuf(s_key,      profile.accessKeyId);
    fillBuf(s_secret,   profile.secretKey);
    fillBuf(s_region,   profile.region.length > 0
                        ? profile.region : "us-east-1");

    FarDialogItem[ProfDlg.Count] items;
    foreach (ref it; items)
        memset(&it, 0, FarDialogItem.sizeof);

    void set(int idx, FARDIALOGITEMTYPES type,
             int x1, int y1, int x2, int y2,
             const(wchar)* text,
             FARDIALOGITEMFLAGS flags = DIF_NONE)
    {
        items[idx].Type  = type;
        items[idx].X1    = x1;  items[idx].Y1 = y1;
        items[idx].X2    = x2;  items[idx].Y2 = y2;
        items[idx].Data  = text;
        items[idx].Flags = flags;
    }

    // Y координаты
    enum Y0 = 0;   // рамка верх
    enum Y1 = 1;   // Name
    enum Y2 = 2;   // поле Name
    enum Y3 = 3;   // Endpoint
    enum Y4 = 4;   // поле Endpoint
    enum Y5 = 5;   // Bucket
    enum Y6 = 6;   // поле Bucket
    enum Y7 = 7;   // Access Key
    enum Y8 = 8;   // поле Key
    enum Y9 = 9;   // Secret Key
    enum Y10 = 10; // поле Secret
    enum Y11 = 11; // Region
    enum Y12 = 12; // поле Region
    enum Y13 = 13; // сепаратор
    enum Y14 = 14; // кнопки
    enum Y15 = 15; // рамка низ

    wstring title = (isNew
                     ? "New S3 Connection"w
                     : "Edit S3 Connection"w) ~ '\0';
    static wchar[64] s_title;
    {
        size_t n = title.length < s_title.length
                   ? title.length : s_title.length - 1;
        s_title[0 .. n] = title[0 .. n];
        s_title[n] = '\0';
    }

    // [0] Рамка
    set(ProfDlg.Frame,
        FARDIALOGITEMTYPES.DI_DOUBLEBOX,
        0, Y0, W-1, Y15, s_title.ptr);

    // [1][2] Name
    set(ProfDlg.LblName,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y1, W-3, Y1,
        "Connection name:\0"w.ptr);
    set(ProfDlg.TxtName,
        FARDIALOGITEMTYPES.DI_EDIT,
        2, Y2, W-3, Y2,
        s_name.ptr,
        DIF_FOCUS);

    // [3][4] Endpoint
    set(ProfDlg.LblEndpoint,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y3, W-3, Y3,
        "Endpoint URL (e.g. https://s3.example.com):\0"w.ptr);

    set(ProfDlg.TxtEndpoint,
        FARDIALOGITEMTYPES.DI_EDIT,
        2, Y4, W-3, Y4,
        s_endpoint.ptr);

    // [5][6] Bucket
    set(ProfDlg.LblBucket,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y5, W-3, Y5,
        "Default bucket (empty = show all):\0"w.ptr);
    set(ProfDlg.TxtBucket,
        FARDIALOGITEMTYPES.DI_EDIT,
        2, Y6, W-3, Y6,
        s_bucket.ptr);

    // [7][8] Access Key
    set(ProfDlg.LblKey,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y7, W-3, Y7,
        "Access Key ID:\0"w.ptr);
    set(ProfDlg.TxtKey,
        FARDIALOGITEMTYPES.DI_EDIT,
        2, Y8, W-3, Y8,
        s_key.ptr);

    // [9][10] Secret Key
    set(ProfDlg.LblSecret,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y9, W-3, Y9,
        "Secret Access Key:\0"w.ptr);
    // set(ProfDlg.TxtSecret,
    //     FARDIALOGITEMTYPES.DI_EDIT,
    //     2, Y10, W-3, Y10,
    //     s_secret.ptr,
    //     DIF_MASKPASSWORD);   // скрываем секрет
    set(ProfDlg.TxtSecret,
        FARDIALOGITEMTYPES.DI_EDIT,
        2, Y10, W-3, Y10,
        s_secret.ptr,
        DIF_NONE);

    // [11][12] Region
    set(ProfDlg.LblRegion,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y11, W-3, Y11,
        "Region:\0"w.ptr);
    set(ProfDlg.TxtRegion,
        FARDIALOGITEMTYPES.DI_EDIT,
        2, Y12, W-3, Y12,
        s_region.ptr);

    // [13] Сепаратор
    set(ProfDlg.Sep,
        FARDIALOGITEMTYPES.DI_TEXT,
        0, Y13, W-1, Y13,
        null,
        DIF_SEPARATOR);

    // [14][15] Кнопки
    set(ProfDlg.BtnOk,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y14, 0, Y14,
        "OK\0"w.ptr,
        DIF_CENTERGROUP | DIF_DEFAULTBUTTON);
    set(ProfDlg.BtnCancel,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y14, 0, Y14,
        "Cancel\0"w.ptr,
        DIF_CENTERGROUP);

    HANDLE hDlg = g_Info.DialogInit(
        &c_PluginGuid,
        &c_DialogGuid,
        -1, -1,
        W, Y15 + 2,
        null,
        items.ptr,
        ProfDlg.Count,
        0,
        FDLG_NONE,
        null,
        null);

    if (hDlg == INVALID_HANDLE_VALUE) return false;
    scope(exit) g_Info.DialogFree(hDlg);

    ptrdiff_t res = g_Info.DialogRun(hDlg);
    debugLog("showProfileDialog: res=" ~ res.to!string);

    if (res != ProfDlg.BtnOk) return false;

    // ── Читаем поля через DM_GETTEXT ──────────────────────
    // Первый вызов с null возвращает длину строки
    // Второй вызов с буфером заполняет его
    string readField(int idx, wchar[] stackBuf)
    {
        stackBuf[0] = '\0';

        FarDialogItemData d;
        d.StructSize = FarDialogItemData.sizeof;
        d.PtrLength  = stackBuf.length - 1;  // без нулевого терминатора
        d.PtrData    = stackBuf.ptr;

        g_Info.SendDlgMessage(
            hDlg,
            FARMESSAGE.DM_GETTEXT,
            idx,
            &d);   // ← передаём структуру, не указатель на буфер

        // Ищем реальную длину
        size_t realLen = 0;
        while (realLen < stackBuf.length &&
            stackBuf[realLen] != '\0')
            realLen++;

        return stackBuf[0 .. realLen].to!string;
    }

    // Вызовы без изменений:
    wchar[512] buf_name;
    wchar[512] buf_endpoint;
    wchar[512] buf_bucket;
    wchar[256] buf_key;
    wchar[256] buf_secret;
    wchar[64]  buf_region;

    profile.name        = readField(ProfDlg.TxtName,     buf_name[]);
    profile.endpoint    = readField(ProfDlg.TxtEndpoint, buf_endpoint[]);
    profile.bucket      = readField(ProfDlg.TxtBucket,   buf_bucket[]);
    profile.accessKeyId = readField(ProfDlg.TxtKey,      buf_key[]);
    profile.secretKey   = readField(ProfDlg.TxtSecret,   buf_secret[]);
    profile.region      = readField(ProfDlg.TxtRegion,   buf_region[]);

    debugLog("showProfileDialog: name="     ~ profile.name);
    debugLog("showProfileDialog: endpoint=" ~ profile.endpoint);
    debugLog("showProfileDialog: region="   ~ profile.region);

    if (profile.name.length == 0)
        profile.name = "Unnamed";
    if (profile.region.length == 0)
        profile.region = "us-east-1";
    return true;
}

// ── Действия с профилями ──────────────────────────────────────

private void createNewProfile(ref S3PanelState state)
{
    S3Profile profile;
    profile.region = "us-east-1";

    debugLog("createNewProfile: opening dialog");

    if (!showProfileDialog(profile, true))
    {
        debugLog("createNewProfile: cancelled");
        return;
    }

    if (profile.endpoint.length == 0)
    {
        debugLog("createNewProfile: endpoint is empty");
        showErrorStr("Endpoint URL is required");
        return;
    }

    debugLog("createNewProfile: saving " ~ profile.name);

    state.settings.profiles ~= profile;
    saveSettings(settingsPath(), *state.settings);

    state.pendingCursorName = profile.name;

    g_Info.PanelControl(
        cast(HANDLE) &state,          // ← &state — адрес ref
        FILE_CONTROL_COMMANDS.FCTL_UPDATEPANEL,
        0, null);

    if (state.pendingCursorName.length > 0)
    {
        g_pendingCursorState = &state; // ← &state
        g_Info.AdvControl(
            &c_PluginGuid,
            ADVANCED_CONTROL_COMMANDS.ACTL_SYNCHRO,
            0, null);
    }
}

private void editCurrentProfile(ref S3PanelState state)
{
    int idx = getCurrentPanelItemIndex(state);
    if (idx < 0 ||
        idx >= cast(int) state.settings.profiles.length)
        return;

    auto profile = state.settings.profiles[idx];
    if (!showProfileDialog(profile, false)) return;

    state.settings.profiles[idx] = profile;
    saveSettings(settingsPath(), *state.settings);

    g_Info.PanelControl(
        cast(HANDLE) &state,
        FILE_CONTROL_COMMANDS.FCTL_UPDATEPANEL,
        0, null);

    debugLog("editCurrentProfile: " ~ profile.name);
}

private void duplicateCurrentProfile(ref S3PanelState state)
{
    int idx = getCurrentPanelItemIndex(state);
    if (idx < 0 ||
        idx >= cast(int) state.settings.profiles.length)
        return;

    auto profile     = state.settings.profiles[idx];
    profile.name     = profile.name ~ " (copy)";

    if (!showProfileDialog(profile, false)) return;

    // Вставляем после текущего
    state.settings.profiles =
        state.settings.profiles[0 .. idx+1] ~
        profile ~
        state.settings.profiles[idx+1 .. $];

    saveSettings(settingsPath(), *state.settings);

    state.pendingCursorName = profile.name;

    g_Info.PanelControl(
        cast(HANDLE) &state,
        FILE_CONTROL_COMMANDS.FCTL_UPDATEPANEL,
        0, null);

    if (state.pendingCursorName.length > 0)
    {
        g_pendingCursorState = &state;
        g_Info.AdvControl(
            &c_PluginGuid,
            ADVANCED_CONTROL_COMMANDS.ACTL_SYNCHRO,
            0, null);
    }

    debugLog("duplicateCurrentProfile: " ~ profile.name);
}

private void renameCurrentProfile(ref S3PanelState state)
{
    int idx = getCurrentPanelItemIndex(state);
    if (idx < 0 ||
        idx >= cast(int) state.settings.profiles.length)
        return;

    // Простой диалог ввода нового имени
    static wchar[256] s_newName;
    auto oldName = state.settings.profiles[idx].name;
    {
        auto ws = oldName.to!wstring;
        size_t n = ws.length < s_newName.length - 1
                   ? ws.length : s_newName.length - 1;
        s_newName[0 .. n] = ws[0 .. n];
        s_newName[n] = '\0';
    }

    import core.stdc.string : memset;

    FarDialogItem[5] items;
    foreach (ref it; items) memset(&it, 0, it.sizeof);

    items[0].Type  = FARDIALOGITEMTYPES.DI_DOUBLEBOX;
    items[0].X1 = 0; items[0].Y1 = 0;
    items[0].X2 = 50; items[0].Y2 = 4;
    items[0].Data  = "Rename connection\0"w.ptr;

    items[1].Type  = FARDIALOGITEMTYPES.DI_TEXT;
    items[1].X1 = 2; items[1].Y1 = 1;
    items[1].X2 = 48; items[1].Y2 = 1;
    items[1].Data  = "New name:\0"w.ptr;

    items[2].Type  = FARDIALOGITEMTYPES.DI_EDIT;
    items[2].X1 = 2; items[2].Y1 = 2;
    items[2].X2 = 48; items[2].Y2 = 2;
    items[2].Data  = s_newName.ptr;
    items[2].Flags = DIF_FOCUS;

    items[3].Type  = FARDIALOGITEMTYPES.DI_BUTTON;
    items[3].X1 = 0; items[3].Y1 = 3;
    items[3].Data  = "OK\0"w.ptr;
    items[3].Flags = DIF_CENTERGROUP | DIF_DEFAULTBUTTON;

    items[4].Type  = FARDIALOGITEMTYPES.DI_BUTTON;
    items[4].X1 = 0; items[4].Y1 = 3;
    items[4].Data  = "Cancel\0"w.ptr;
    items[4].Flags = DIF_CENTERGROUP;

    HANDLE hDlg = g_Info.DialogInit(
        &c_PluginGuid, &c_DialogGuid,
        -1, -1, 52, 6,
        null, items.ptr, 5, 0,
        FDLG_NONE, null, null);

    if (hDlg == INVALID_HANDLE_VALUE) return;
    scope(exit) g_Info.DialogFree(hDlg);

    if (g_Info.DialogRun(hDlg) != 3) return; // 3 = BtnOk

    // Читаем новое имя
    FarDialogItemData d;
    d.StructSize = FarDialogItemData.sizeof;
    d.PtrLength  = 0;
    d.PtrData    = null;
    g_Info.SendDlgMessage(hDlg,
        FARMESSAGE.DM_GETDLGITEMSHORT, 2, &d);

    if (d.PtrLength == 0) return;
    auto buf = new wchar[d.PtrLength + 1];
    buf[d.PtrLength] = '\0';
    d.PtrData = buf.ptr;
    g_Info.SendDlgMessage(hDlg,
        FARMESSAGE.DM_GETDLGITEMSHORT, 2, &d);

    string newName = buf[0 .. d.PtrLength].to!string;
    if (newName.length == 0) return;

    state.settings.profiles[idx].name = newName;
    saveSettings(settingsPath(), *state.settings);

    state.pendingCursorName = newName;

    g_Info.PanelControl(
        cast(HANDLE) &state,
        FILE_CONTROL_COMMANDS.FCTL_UPDATEPANEL,
        0, null);

    if (state.pendingCursorName.length > 0)
    {
        g_pendingCursorState = &state;
        g_Info.AdvControl(
            &c_PluginGuid,
            ADVANCED_CONTROL_COMMANDS.ACTL_SYNCHRO,
            0, null);
    }

    debugLog("renameCurrentProfile: " ~
             oldName ~ " → " ~ newName);
}

private void deleteCurrentProfile(ref S3PanelState state)
{
    int idx = getCurrentPanelItemIndex(state);
    if (idx < 0 ||
        idx >= cast(int) state.settings.profiles.length)
        return;

    string  name  = state.settings.profiles[idx].name;
    wstring nameW = name.to!wstring;

    static wchar[256] s_nameBuf;
    {
        size_t n = nameW.length < s_nameBuf.length - 1
                   ? nameW.length : s_nameBuf.length - 1;
        s_nameBuf[0 .. n] = nameW[0 .. n];
        s_nameBuf[n] = '\0';
    }

    // ← убраны все промежуточные массивы lines/allLines
    const(wchar)*[5] dlgLines = [
        "Delete connection\0"w.ptr,
        "Delete connection?\0"w.ptr,
        s_nameBuf.ptr,
        "Delete\0"w.ptr,
        "Cancel\0"w.ptr,
    ];

    int res = cast(int) g_Info.Message(
        &c_PluginGuid,
        &c_PluginGuid,
        FMSG_WARNING,
        null,
        dlgLines.ptr,
        5,    // всего строк включая кнопки
        2);   // кол-во кнопок

    if (res != 0) return; // 0 = Delete

    state.settings.profiles =
        state.settings.profiles[0 .. idx] ~
        state.settings.profiles[idx+1 .. $];

    saveSettings(settingsPath(), *state.settings);

    g_Info.PanelControl(
        cast(HANDLE) &state,
        FILE_CONTROL_COMMANDS.FCTL_UPDATEPANEL,
        0, null);

    debugLog("deleteCurrentProfile: " ~ name);
}

// Получаем индекс текущего элемента панели
private int getCurrentPanelItemIndex(ref S3PanelState state)
{
    PanelInfo pi;
    pi.StructSize = PanelInfo.sizeof;

    if (g_Info.PanelControl(
            cast(HANDLE) &state,
            FILE_CONTROL_COMMANDS.FCTL_GETPANELINFO,
            0, &pi) == 0)
        return -1;

    return cast(int) pi.CurrentItem;
}