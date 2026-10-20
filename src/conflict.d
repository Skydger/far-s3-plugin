module conflict;

import farplugin;
import s3log;

import core.sys.windows.windows : GUID, HANDLE, INVALID_HANDLE_VALUE;
import core.stdc.string         : memset;
import std.conv                 : to;
import std.format               : format;
import std.file                 : exists, getSize, timeLastModified;
import std.datetime             : SysTime;

// ──────────────────────────────────────────────────────────────
enum ConflictChoice
{
    Ask,
    Overwrite,
    Skip,
    Rename,
    Append,
    Cancel,
}


// Вместо DIF_SEPARATOR рисуем линию вручную
// ╟────────────────────────────────────────────────────────────────────────╢
// Для DI_DOUBLEBOX стыковочные символы: ╟ (U+255F) и ╢ (U+2562)
// Линия: ─ (U+2500)

private wstring makeSeparatorLine(int innerWidth)
{
    // innerWidth = W - 2 (пространство внутри рамки)
    wstring line;
    line ~= '\u255F';                    // ╟
    foreach (_; 0 .. innerWidth - 2)
        line ~= '\u2500';                // ─
    line ~= '\u2562';                    // ╢
    return line;
}

// Статические буферы для сепараторов
// (нужны три одинаковых — каждый имеет свой указатель)
static wchar[128] s_sep1;
static wchar[128] s_sep2;
static wchar[128] s_sep3;

// ──────────────────────────────────────────────────────────────
// Утилиты
// ──────────────────────────────────────────────────────────────

// MD5 существующего локального файла (для сравнения с ETag)
private string fileMD5(string path)
{
    import std.file      : read;
    import std.digest    : toHexString, LetterCase;
    import std.digest.md : md5Of;
    try
    {
        auto data = cast(ubyte[]) read(path);
        return toHexString!(LetterCase.lower)(md5Of(data)).idup;
    }
    catch (Exception e)
    {
        debugLog("fileMD5 error: " ~ e.msg);
        return "??";
    }
}

private wstring fileDateTime(string path)
{
    try
    {
        SysTime t = timeLastModified(path);
        return "%02d.%02d.%04d %02d:%02d:%02d"w.format(
            t.day, cast(int) t.month, t.year,
            t.hour, t.minute, t.second).to!wstring;
    }
    catch (Exception e) { return "??"w; }
}

wstring formatBytes(ulong bytes)
{
    if (bytes < 1024)
        return bytes.to!wstring ~ " B"w;
    else if (bytes < 1024 * 1024)
        return "%.1f KB"w.format(bytes / 1024.0).to!wstring;
    else if (bytes < 1024UL * 1024 * 1024)
        return "%.1f MB"w.format(
            bytes / (1024.0 * 1024)).to!wstring;
    else
        return "%.2f GB"w.format(
            bytes / (1024.0 * 1024 * 1024)).to!wstring;
}

private void fillW(size_t N)(ref wchar[N] buf, wstring s)
{
    size_t n = s.length < N - 1 ? s.length : N - 1;
    buf[0 .. n] = s[0 .. n];
    buf[n] = '\0';
}

// Строка фиксированной ширины с пробелами справа
private wstring padRight(wstring s, size_t width)
{
    if (s.length >= width) return s[0 .. width];
    wstring pad;
    foreach (_; 0 .. width - s.length) pad ~= ' ';
    return s ~ pad;
}

// ──────────────────────────────────────────────────────────────
// Индексы элементов диалога
// ──────────────────────────────────────────────────────────────
private enum DlgItem : int
{
    Frame        = 0,
    TxtHeader    = 1,
    TxtPath      = 2,
    Sep1         = 3,
    TxtNew       = 4,
    TxtExisting  = 5,
    Sep2         = 6,
    ChkRemember  = 7,
    Sep3         = 8,
    BtnOverwrite = 9,
    BtnSkip      = 10,
    BtnRename    = 11,
    BtnAppend    = 12,
    BtnCancel    = 13,
    Count        = 14,
}

// ──────────────────────────────────────────────────────────────
// Диалог конфликта
//
// newChecksum — строка от S3 (ETag/MD5 или CRC32):
//   "MD5: d41d8cd98f00b204e9800998ecf8427e"
//   "CRC32: AABBCCDD"
//   "" — если не удалось получить
// ──────────────────────────────────────────────────────────────
ConflictChoice showConflictDialog(
    ref const PluginStartupInfo psi,
    ref const GUID              pluginGuid,
    ref const GUID              dialogGuid,
    string                      localPath,
    ulong                       newSize,
    string                      newChecksum,
    ref bool                    rememberOut)
{
    enum W     = 74;      // ширина диалога
    enum INNER = W - 4;   // ширина текста (отступ 2 слева + 2 справа)

    // W=74, innerWidth = W-2 = 72
    auto sepLine = makeSeparatorLine(W - 2);
    fillW(s_sep1, sepLine);
    fillW(s_sep2, sepLine);
    fillW(s_sep3, sepLine);

    // ── Путь ─────────────────────────────────────────────
    wstring wPath = localPath.to!wstring;
    if (wPath.length > INNER)
        wPath = "..."w ~ wPath[wPath.length - (INNER - 3) .. $];

    // ── Дата нового файла = сейчас ────────────────────────
    import std.datetime : Clock;
    auto    now     = Clock.currTime();
    wstring newDate = "%02d.%02d.%04d %02d:%02d:%02d"w.format(
        now.day, cast(int) now.month, now.year,
        now.hour, now.minute, now.second).to!wstring;

    // ── Данные существующего файла ────────────────────────
    ulong   existSize     = 0;
    wstring existDate     = "??"w;
    string  existChecksum = "";
    if (exists(localPath))
    {
        try { existSize = getSize(localPath); } catch (Exception e) {}
        existDate     = fileDateTime(localPath);
        existChecksum = "MD5: " ~ fileMD5(localPath);
    }

    // Форматируем newChecksum для отображения
    wstring newChecksumW  = newChecksum.length  > 0
                            ? newChecksum.to!wstring
                            : "??"w;
    wstring existChecksumW = existChecksum.length > 0
                            ? existChecksum.to!wstring
                            : "??"w;

    // ── Строим строки New/Existing ────────────────────────
    // Формат: "Label    SIZE      DATE                  CHECKSUM"
    // Выравниваем по правому краю INNER
    wstring buildInfoLine(wstring label,
                          ulong   sz,
                          wstring date,
                          wstring checksum)
    {
        wstring szStr  = formatBytes(sz);
        wstring line   = padRight(label,   9)  ~   // "New      "
                         padRight(szStr,   10) ~   // "21.8 MB   "
                         padRight(date,    21) ~   // "19.04.2026 18:55:03  "
                         checksum;

        // Выравниваем по правому краю
        if (line.length < INNER)
        {
            wstring pad;
            foreach (_; 0 .. INNER - line.length) pad ~= ' ';
            line = pad ~ line;
        }
        else if (line.length > INNER)
        {
            line = line[0 .. INNER];
        }
        return line;
    }

    wstring wNew   = buildInfoLine(
        "New"w,      newSize,   newDate,   newChecksumW);
    wstring wExist = buildInfoLine(
        "Existing"w, existSize, existDate, existChecksumW);

    // ── Статические буферы ────────────────────────────────
    static wchar[256] s_path;
    static wchar[256] s_new;
    static wchar[256] s_exist;

    fillW(s_path,  wPath);
    fillW(s_new,   wNew);
    fillW(s_exist, wExist);

    // ── Y-координаты ──────────────────────────────────────
    enum Y_FRAME  = 0;
    enum Y_HEADER = 1;
    enum Y_PATH   = 2;
    enum Y_SEP1   = 3;
    enum Y_NEW    = 4;
    enum Y_EXIST  = 5;
    enum Y_SEP2   = 6;
    enum Y_CHK    = 7;
    enum Y_SEP3   = 8;
    enum Y_BTN    = 9;   // все кнопки в один ряд
    enum Y_BOTTOM = 10;

    // ── Элементы диалога ──────────────────────────────────
    FarDialogItem[DlgItem.Count] items;
    foreach (ref it; items)
        memset(&it, 0, FarDialogItem.sizeof);

    void set(int               idx,
             FARDIALOGITEMTYPES type,
             int                x1, int y1, int x2, int y2,
             const(wchar)*      text,
             FARDIALOGITEMFLAGS flags = DIF_NONE)
    {
        items[idx].Type  = type;
        items[idx].X1    = x1;
        items[idx].Y1    = y1;
        items[idx].X2    = x2;
        items[idx].Y2    = y2;
        items[idx].Data  = text;
        items[idx].Flags = flags;
    }

    // [0] Рамка
    set(DlgItem.Frame,
        FARDIALOGITEMTYPES.DI_DOUBLEBOX,
        0, Y_FRAME, W-1, Y_BOTTOM,
        "Warning\0"w.ptr);

    // [1] "File already exists" по центру
    set(DlgItem.TxtHeader,
        FARDIALOGITEMTYPES.DI_TEXT,
        0, Y_HEADER, W-1, Y_HEADER,
        "File already exists\0"w.ptr,
        DIF_CENTERTEXT);

    // [2] Путь
    set(DlgItem.TxtPath,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y_PATH, W-3, Y_PATH,
        s_path.ptr);

    // [3] Сепаратор — X1=0, X2=W-1 стыкуется с рамкой
    // [3] Сепаратор после пути
    set(DlgItem.Sep1,
        FARDIALOGITEMTYPES.DI_TEXT,
        1, Y_SEP1, W-2, Y_SEP1,   // ← X1=1, X2=W-2
        s_sep1.ptr,
        DIF_NONE);
    // [4] New
    set(DlgItem.TxtNew,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y_NEW, W-3, Y_NEW,
        s_new.ptr);

    // [5] Existing
    set(DlgItem.TxtExisting,
        FARDIALOGITEMTYPES.DI_TEXT,
        2, Y_EXIST, W-3, Y_EXIST,
        s_exist.ptr);

    // [6] Сепаратор после New/Existing
    set(DlgItem.Sep2,
        FARDIALOGITEMTYPES.DI_TEXT,
        1, Y_SEP2, W-2, Y_SEP2,
        s_sep2.ptr,
        DIF_NONE);

    // [7] Чекбокс
    set(DlgItem.ChkRemember,
        FARDIALOGITEMTYPES.DI_CHECKBOX,
        2, Y_CHK, W-3, Y_CHK,
        "Remember choice\0"w.ptr,
        DIF_NONE);
    items[DlgItem.ChkRemember].Selected = FARCHECKEDSTATE.BSTATE_UNCHECKED;

    // [8] Сепаратор перед кнопками
    set(DlgItem.Sep3,
        FARDIALOGITEMTYPES.DI_TEXT,
        1, Y_SEP3, W-2, Y_SEP3,
        s_sep3.ptr,
        DIF_NONE);

    // Все 5 кнопок в один ряд через DIF_CENTERGROUP
    // [9] Overwrite
    set(DlgItem.BtnOverwrite,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y_BTN, 0, Y_BTN,
        "Overwrite\0"w.ptr,
        DIF_CENTERGROUP | DIF_DEFAULTBUTTON);

    // [10] Skip
    set(DlgItem.BtnSkip,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y_BTN, 0, Y_BTN,
        "Skip\0"w.ptr,
        DIF_CENTERGROUP);

    // [11] Rename
    set(DlgItem.BtnRename,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y_BTN, 0, Y_BTN,
        "Rename\0"w.ptr,
        DIF_CENTERGROUP);

    // [12] Append
    set(DlgItem.BtnAppend,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y_BTN, 0, Y_BTN,
        "Append\0"w.ptr,
        DIF_CENTERGROUP);

    // [13] Cancel
    set(DlgItem.BtnCancel,
        FARDIALOGITEMTYPES.DI_BUTTON,
        0, Y_BTN, 0, Y_BTN,
        "Cancel\0"w.ptr,
        DIF_CENTERGROUP);

    // ── Запускаем диалог ──────────────────────────────────
    HANDLE hDlg = psi.DialogInit(
        &pluginGuid,
        &dialogGuid,
        -1, -1,
        W, Y_BOTTOM + 2,
        null,
        items.ptr,
        DlgItem.Count,
        0,
        FDLG_WARNING,
        null,
        null);

    if (hDlg == INVALID_HANDLE_VALUE)
    {
        debugLog("showConflictDialog: DialogInit failed");
        return ConflictChoice.Cancel;
    }

    scope(exit) psi.DialogFree(hDlg);

    ptrdiff_t res = psi.DialogRun(hDlg);
    debugLog("conflict DialogRun=" ~ res.to!string);

    // ── Читаем чекбокс ────────────────────────────────────
    ptrdiff_t chkVal = psi.SendDlgMessage(
        hDlg,
        FARMESSAGE.DM_GETCHECK,
        DlgItem.ChkRemember,
        null);
    rememberOut = (chkVal == FARCHECKEDSTATE.BSTATE_CHECKED);

    // ── Маппинг результата ────────────────────────────────
    switch (res)
    {
        case DlgItem.BtnOverwrite: return ConflictChoice.Overwrite;
        case DlgItem.BtnSkip:      return ConflictChoice.Skip;
        case DlgItem.BtnRename:    return ConflictChoice.Rename;
        case DlgItem.BtnAppend:    return ConflictChoice.Append;
        default:                   return ConflictChoice.Cancel;
    }
}
