module s3.client;

import std.net.curl;
import std.stdio        : writefln, stderr;
import std.file         : read, write, mkdirRecurse;
import std.path         : dirName;
import std.string       : format, replace, strip, indexOf;
import std.array        : join, appender;
import std.algorithm    : min, endsWith;
import std.conv         : to;
import std.digest       : toHexString, LetterCase;
import std.datetime     : Clock, UTC;
import std.digest.sha   : sha256Of, SHA256;
import std.digest.hmac  : hmac;
import std.digest.crc   : crc32Of;
import std.regex        : matchAll, regex;
import s3log;

// ──────────────────────────────────────────────────────────────
// Результат listBuckets()
// ──────────────────────────────────────────────────────────────
struct S3Bucket
{
    string name;
    string creationDate; // ISO 8601
}

// ──────────────────────────────────────────────────────────────
// Результат listObjectsV2() с разделителем
// ──────────────────────────────────────────────────────────────
struct S3Object
{
    string key;
    ulong  size;
    string lastModified;
    bool   isDirectory; // true если это CommonPrefix (виртуальная "папка")
}

struct S3Client
{
    string endpoint;
    string akId;
    string sakId;
    string region;
    string bucket; // текущий бакет (можно менять)

struct S3ObjectMeta
{
    ulong  size;
    string etag;         // MD5 или составной
    string lastModified;
    string checksumCRC32; // x-amz-checksum-crc32 если есть
}

S3ObjectMeta headObject(string s3Key)
{
    import s3log : debugLog;

    string normalizedKey = s3Key.replace("\\", "/");
    auto url  = "%s/%s/%s".format(endpoint, bucket,
                                   uriEncodePath(normalizedKey));
    auto path = "/%s/%s".format(bucket,
                                 uriEncodePath(normalizedKey));

    debugLog("headObject: " ~ url);

    auto http = HTTP(url);
    http.method = HTTP.Method.head;
    signRequest(http, "HEAD", path, "", "");

    int          statusCode;
    S3ObjectMeta meta;

    http.onReceiveStatusLine = (HTTP.StatusLine sl) {
        statusCode = sl.code;
    };

    http.onReceiveHeader = (in char[] key, in char[] value) {
        import std.string : toLower, strip;
        auto k = key.toLower;
        auto v = value.strip().idup;
        switch (k)
        {
            case "etag":
                // Убираем кавычки: "abc123" → abc123
                meta.etag = (v.length >= 2 &&
                             v[0] == '"' && v[$-1] == '"')
                            ? v[1 .. $-1] : v;
                break;
            case "content-length":
                try { meta.size = v.to!ulong; } catch (Exception e) {}
                break;
            case "last-modified":
                meta.lastModified = v;
                break;
            case "x-amz-checksum-crc32":
                meta.checksumCRC32 = v;
                break;
            default: break;
        }
    };

    // HEAD не возвращает тело — нужен пустой onReceive
    http.onReceive = (ubyte[] data) { return data.length; };

    http.perform();

    debugLog("headObject: HTTP " ~ statusCode.to!string ~
             " size=" ~ meta.size.to!string ~
             " etag=" ~ meta.etag ~
             " crc32=" ~ meta.checksumCRC32);

    if (statusCode < 200 || statusCode >= 300)
        throw new Exception(
            "S3 HEAD failed [HTTP " ~
            statusCode.to!string ~ "]: " ~ normalizedKey);

    return meta;
}
// ──────────────────────────────────────────────────────
// Список бакетов аккаунта
// ──────────────────────────────────────────────────────
S3Bucket[] listBuckets()
{
    import s3log : debugLog;

    auto url  = endpoint ~ "/";
    auto path = "/";

    string respBody;
    int    statusCode;

    auto http = HTTP(url);
    http.method = HTTP.Method.get;
    signRequest(http, "GET", path, "", "");

    http.onReceiveStatusLine = (HTTP.StatusLine sl) {
        statusCode = sl.code;
    };
    http.onReceive = (ubyte[] data) {
        respBody ~= cast(string) data;
        return data.length;
    };
    http.perform();

    debugLog("listBuckets: HTTP " ~ statusCode.to!string);
    size_t logLen = respBody.length < 1000 ? respBody.length : 1000;
    debugLog("listBuckets response: " ~ respBody[0 .. logLen]);

    if (statusCode < 200 || statusCode >= 300)
        throw new Exception(
            "S3 listBuckets failed [HTTP %d]: %s"
            .format(statusCode, respBody));

    return parseListBucketsResponse(respBody);
}

// ──────────────────────────────────────────────────────
// Парсинг XML ответа ListBuckets
// ──────────────────────────────────────────────────────
private S3Bucket[] parseListBucketsResponse(string xml)
{
    import s3log    : debugLog;
    import std.string : strip, indexOf;

    S3Bucket[] buckets;
    size_t pos = 0;

    while (true)
    {
        auto blockStart = xml.indexOf("<Bucket>", pos);
        if (blockStart < 0) break;
        auto blockEnd = xml.indexOf("</Bucket>", blockStart);
        if (blockEnd < 0) break;

        string block = xml[blockStart .. blockEnd];
        string name  = extractTag(block, "Name").strip();
        string cdate = extractTag(block, "CreationDate").strip();

        if (name.length > 0)
        {
            buckets ~= S3Bucket(name, cdate);
            debugLog("  bucket: [" ~ name ~ "] created=" ~ cdate);
        }

        pos = blockEnd + 1;
    }

    debugLog("parseListBucketsResponse: total=" ~
             buckets.length.to!string);

    return buckets;
}

    // ──────────────────────────────────────────────────────
    // Список объектов с поддержкой "папок" (CommonPrefixes)
    //
    // prefix    — текущий путь внутри бакета, например "folder/"
    // delimiter — разделитель, "/" для навигации по папкам
    //
    // Возвращает:
    //   - S3Object с isDirectory=true  → виртуальные "папки"
    //   - S3Object с isDirectory=false → реальные объекты
    // ──────────────────────────────────────────────────────
S3Object[] listObjectsV2(string prefix = "", string delimiter = "/")
{
    import s3log : debugLog;
    import std.string : strip;

    // ── Строим параметры запроса ──────────────────────────
    // AWS требует параметры отсортированные по алфавиту!
    string[string] params;
    params["list-type"] = "2";
    if (delimiter.length > 0)
        params["delimiter"] = delimiter;
    if (prefix.length > 0)
        params["prefix"] = prefix;

    // ── Канонический query string для подписи ─────────────
    // Сортируем ключи, кодируем ключи и значения
    string canonicalQuery = buildCanonicalQuery(params);

    // ── URL для запроса ───────────────────────────────────
    auto url  = "%s/%s?%s".format(endpoint, bucket, canonicalQuery);
    auto path = "/%s".format(bucket);

    debugLog("listObjectsV2: url=" ~ url);
    debugLog("listObjectsV2: canonicalQuery=" ~ canonicalQuery);

    string respBody;
    int    statusCode;

    auto http = HTTP(url);
    http.method = HTTP.Method.get;

    // Передаём канонический query string в signRequest
    signRequest(http, "GET", path, canonicalQuery, "");

    http.onReceiveStatusLine = (HTTP.StatusLine sl) {
        statusCode = sl.code;
    };
    http.onReceive = (ubyte[] data) {
        respBody ~= cast(string) data;
        return data.length;
    };

    http.perform();

    debugLog("listObjectsV2: HTTP " ~ statusCode.to!string);
    size_t logLen = respBody.length < 2000 ? respBody.length : 2000;
    debugLog("response: " ~ respBody[0 .. logLen]);

    if (statusCode < 200 || statusCode >= 300)
        throw new Exception(
            "S3 listObjects failed [HTTP %d]: %s"
            .format(statusCode, respBody));

    return parseListObjectsResponse(respBody, prefix);
}
// ── Парсинг XML без regex — простой и надёжный ───────────────
private S3Object[] parseListObjectsResponse(
    string xml,
    string currentPrefix)
{
    import s3log : debugLog;

    S3Object[] objects;

    // ── Виртуальные "папки" из <CommonPrefixes> ──────────
    size_t pos = 0;
    while (true)
    {
        auto blockStart = xml.indexOf("<CommonPrefixes>", pos);
        if (blockStart < 0) break;
        auto blockEnd = xml.indexOf("</CommonPrefixes>", blockStart);
        if (blockEnd < 0) break;

        string block  = xml[blockStart .. blockEnd];
        string key    = extractTag(block, "Prefix");

        if (key.length > 0)
        {
            objects ~= S3Object(
                key         : key,
                size        : 0,
                lastModified: "",
                isDirectory : true
            );
            debugLog("  DIR: [" ~ key ~ "]");
        }

        pos = blockEnd + 1;
    }

    // ── Реальные объекты из <Contents> ───────────────────
    pos = 0;
    while (true)
    {
        auto blockStart = xml.indexOf("<Contents>", pos);
        if (blockStart < 0) break;
        auto blockEnd = xml.indexOf("</Contents>", blockStart);
        if (blockEnd < 0) break;

        string block        = xml[blockStart .. blockEnd];
        string key          = extractTag(block, "Key");
        string sizeStr      = extractTag(block, "Size");
        string lastModified = extractTag(block, "LastModified");

        debugLog("  Contents block: key=[" ~ key ~
                 "] size=[" ~ sizeStr ~ "]");

        // Пропускаем пустые ключи
        if (key.length == 0)
        {
            pos = blockEnd + 1;
            continue;
        }

        // Пропускаем "папку саму себя"
        if (key == currentPrefix)
        {
            pos = blockEnd + 1;
            continue;
        }

        // Пропускаем ключи оканчивающиеся на /
        // (виртуальные папки без delimiter)
        if (key[$ - 1] == '/')
        {
            pos = blockEnd + 1;
            continue;
        }

        ulong fileSize = 0;
        try
        {
            import std.string : strip;
            fileSize = sizeStr.strip().to!ulong;
        }
        catch(Exception e)
        {
            debugLog("  WARNING: cannot parse size=[" ~ sizeStr ~ "]");
        }

        objects ~= S3Object(
            key         : key,
            size        : fileSize,
            lastModified: lastModified,
            isDirectory : false
        );
        debugLog("  FILE: [" ~ key ~ "] size=" ~ fileSize.to!string);

        pos = blockEnd + 1;
    }

    debugLog("parseListObjectsResponse: total items=" ~
             objects.length.to!string);

    return objects;
}

    // ── Извлечь содержимое первого вхождения тега ────────────────
    private static string extractTag(string xml, string tag)
    {
        import std.string : indexOf;

        string open  = "<"  ~ tag ~ ">";
        string close = "</" ~ tag ~ ">";

        auto s = xml.indexOf(open);
        if (s < 0) return "";
        s += open.length;

        auto e = xml.indexOf(close, s);
        if (e < 0) return "";

        return xml[s .. e];
    }

    private ubyte[] downloadToMemoryWithETag(
        string     s3Key,
        ref string outETag,
        void delegate(ulong received, ulong total) onProgress = null)
    {
        import s3log : debugLog;

        string normalizedKey = s3Key.replace("\\", "/");

        auto url  = "%s/%s/%s".format(endpoint, bucket,
                                    uriEncodePath(normalizedKey));
        auto path = "/%s/%s".format(bucket,
                                    uriEncodePath(normalizedKey));

        debugLog("downloadToMemory: url=" ~ url);

        auto http = HTTP(url);
        http.method = HTTP.Method.get;
        signRequest(http, "GET", path, "", "");

        int    statusCode;
        string etag;
        ulong  contentLength = 0;  // ← получим из заголовков
        ulong  received      = 0;
        auto   buf           = appender!(ubyte[])();

        http.onReceiveStatusLine = (HTTP.StatusLine sl) {
            statusCode = sl.code;
        };

        http.onReceiveHeader = (in char[] key, in char[] value) {
            import std.string : toLower, strip;
            auto k = key.toLower;
            if (k == "etag")
            {
                etag = value.strip().idup;
                debugLog("  ETag: " ~ etag);
            }
            else if (k == "content-length")
            {
                try { contentLength = value.strip().to!ulong; }
                catch (Exception e) {}
                debugLog("  Content-Length: " ~ contentLength.to!string);
            }
        };

        http.onReceive = (ubyte[] data) {
            buf   ~= data;
            received += data.length;

            // Вызываем колбек прогресса если передан
            if (onProgress !is null && contentLength > 0)
                onProgress(received, contentLength);

            return data.length;
        };

        http.perform();

        debugLog("downloadToMemory: HTTP " ~ statusCode.to!string ~
                " bytes=" ~ buf.data.length.to!string);

        if (statusCode < 200 || statusCode >= 300)
            throw new Exception(
                "S3 download failed [HTTP " ~
                statusCode.to!string ~ "]: " ~ normalizedKey);

        outETag = etag;
        return buf.data;
    }

    // ──────────────────────────────────────────────────────
    // Старый listObjects — оставляем для совместимости
    // ──────────────────────────────────────────────────────
    string[] listObjects(string[] fileFilter = null)
    {
        auto objects = listObjectsV2("", ""); // без разделителя = плоский список
        string[] keys;
        foreach (obj; objects)
        {
            if (fileFilter is null || fileFilter.length == 0)
            {
                keys ~= obj.key;
            }
            else
            {
                foreach (f; fileFilter)
                    if (obj.key.endsWith(f)) { keys ~= obj.key; break; }
            }
        }
        return keys;
    }

    // ──────────────────────────────────────────────────────
    // Скачать файл из S3 на диск
    // ──────────────────────────────────────────────────────
    // Листинг ВСЕХ объектов с префиксом (без delimiter = рекурсивно)
    S3Object[] listObjectsRecursive(string prefix = "")
    {
        import s3log : debugLog;

        string[string] params;
        params["list-type"] = "2";
        if (prefix.length > 0)
            params["prefix"] = prefix;
        // delimiter НЕ передаём — получаем всё дерево плоским списком

        string canonicalQuery = buildCanonicalQuery(params);
        auto   url  = "%s/%s?%s".format(endpoint, bucket, canonicalQuery);
        auto   path = "/%s".format(bucket);

        string respBody;
        int    statusCode;

        auto http = HTTP(url);
        http.method = HTTP.Method.get;
        signRequest(http, "GET", path, canonicalQuery, "");

        http.onReceiveStatusLine = (HTTP.StatusLine sl) {
            statusCode = sl.code;
        };
        http.onReceive = (ubyte[] data) {
            respBody ~= cast(string) data;
            return data.length;
        };
        http.perform();

        debugLog("listObjectsRecursive: HTTP " ~ statusCode.to!string);

        if (statusCode < 200 || statusCode >= 300)
            throw new Exception(
                "S3 listObjects failed [HTTP " ~
                statusCode.to!string ~ "]: " ~ respBody);

        // Парсим только <Contents> — папок нет при рекурсивном листинге
        return parseListObjectsResponse(respBody, prefix);
    }


// ──────────────────────────────────────────────────────
// Скачать в память + получить ETag из заголовков
// ──────────────────────────────────────────────────────
string downloadFileWithETag(
    string s3Key,
    string destPath,
    void delegate(ulong received, ulong total) onProgress = null)
{
    import s3log         : debugLog;
    import std.path      : dirName;
    import std.file      : write, mkdirRecurse, FileException;
    import std.digest    : toHexString, LetterCase;
    import std.digest.md : md5Of;

    string normalizedKey  = s3Key.replace("\\", "/");
    string normalizedDest = destPath.replace("\\", "/");

    string serverETag;
    // ── Передаём колбек вниз ──────────────────────────────
    auto body = downloadToMemoryWithETag(normalizedKey, serverETag,
                                         onProgress);

    // ── Проверка ETag / MD5 ───────────────────────────────
    if (serverETag.length > 0 && serverETag.indexOf('-') < 0)
    {
        string cleanETag = serverETag;
        if (cleanETag.length >= 2 &&
            cleanETag[0] == '"' && cleanETag[$ - 1] == '"')
            cleanETag = cleanETag[1 .. $ - 1];

        string localMD5 = toHexString!(LetterCase.lower)(
                              md5Of(body)).idup;

        debugLog("ETag: server=[" ~ cleanETag ~
                 "] local=[" ~ localMD5 ~ "]");

        if (cleanETag != localMD5)
            throw new Exception(
                "Integrity check failed: " ~ normalizedKey ~
                "\nserver=" ~ cleanETag ~
                " local=" ~ localMD5);
    }

    // ── Создаём папку ─────────────────────────────────────
    try { mkdirRecurse(dirName(normalizedDest)); }
    catch (FileException e)
    {
        throw new Exception(
            "Cannot create directory: " ~ normalizedDest ~
            "\n" ~ e.msg);
    }

    // ── Записываем файл ───────────────────────────────────
    try
    {
        write(normalizedDest, body);
        debugLog("Written OK: " ~ normalizedDest);
    }
    catch (FileException e)
    {
        throw new Exception(
            "Cannot write file: " ~ normalizedDest ~
            "\nReason: " ~ e.msg);
    }

    return serverETag;
}

// downloadFile через downloadFileWithETag:
void downloadFile(string s3Key, string destPath)
{
    string etag;
    // просто вызываем новую версию, etag игнорируем
    downloadFileWithETag(s3Key, destPath);
}

// downloadToMemory для совместимости (используется в getObjectCRC32):
ubyte[] downloadToMemory(string s3Key)
{
    string etag;
    return downloadToMemoryWithETag(s3Key, etag);
}

    // ──────────────────────────────────────────────────────
    // Загрузить файл в S3
    // ──────────────────────────────────────────────────────
    void uploadFile(string s3Key, string filePath)
    {
        string normalizedPath = filePath.replace("\\", "/");
        string normalizedKey  = s3Key.replace("\\", "/");

        auto   body     = cast(ubyte[]) read(normalizedPath);
        string bodyHash = toHexString!(LetterCase.lower)(sha256Of(body).dup);

        auto url  = "%s/%s/%s".format(endpoint, bucket, normalizedKey);
        auto path = "/%s/%s".format(bucket, normalizedKey);

        auto http = HTTP(url);
        http.method = HTTP.Method.put;
        signRequest(http, "PUT", path, "", bodyHash);
        http.addRequestHeader("Content-Length", body.length.to!string);
        http.contentLength = body.length;

        int    statusCode;
        string respBody;

        http.onReceiveStatusLine = (HTTP.StatusLine sl) { statusCode = sl.code; };
        http.onReceive = (ubyte[] data) {
            respBody ~= cast(string) data;
            return data.length;
        };

        size_t offset = 0;
        http.onSend = (void[] buf) {
            size_t take = min(buf.length, body.length - offset);
            if (take == 0) return 0;
            buf[0 .. take] = body[offset .. offset + take];
            offset += take;
            return take;
        };

        try
        {
            http.perform();
            if (statusCode >= 200 && statusCode < 300)
                writefln("Uploaded [HTTP %d]: %s <- %s", statusCode, normalizedKey, normalizedPath);
            else
            {
                stderr.writefln("Upload failed [HTTP %d]: %s", statusCode, normalizedKey);
                throw new Exception("S3 upload failed with HTTP %d".format(statusCode));
            }
        }
        catch (Exception e)
        {
            stderr.writefln("Upload error [%s]: %s", normalizedKey, e.message);
            throw e;
        }
    }

    // ──────────────────────────────────────────────────────
    // CRC32 объекта в S3
    // ──────────────────────────────────────────────────────
    string getObjectCRC32(string s3Key)
    {
        auto body = downloadToMemory(s3Key);
        auto crc  = crc32Of(body);
        return "%08X".format(
            (cast(uint) crc[0])       |
            (cast(uint) crc[1] <<  8) |
            (cast(uint) crc[2] << 16) |
            (cast(uint) crc[3] << 24)
        );
    }

private:

    // ──────────────────────────────────────────────────────
    // URI encode (только то, что нужно для query string)
    // ──────────────────────────────────────────────────────
// ── URI encode для пути (/ не кодируем) ──────────────────────
private static string uriEncodePath(string s)
{
    auto result = appender!string();
    foreach (char c; s)
    {
        if ((c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            c == '-' || c == '_'   ||
            c == '.' || c == '~'   ||
            c == '/')                 // ← путь: слэш не кодируем
            result ~= c;
        else
            result ~= "%%%02X".format(cast(ubyte) c);
    }
    return result.data;
}

// ── URI encode для query string (/ кодируем как %2F) ─────────
private static string uriEncodeQuery(string s)
{
    auto result = appender!string();
    foreach (char c; s)
    {
        if ((c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            c == '-' || c == '_'   ||
            c == '.' || c == '~')     // ← query: / кодируем!
            result ~= c;
        else
            result ~= "%%%02X".format(cast(ubyte) c);
    }
    return result.data;
}
    // ──────────────────────────────────────────────────────
    // AWS Signature V4 — без изменений, твой код работает
    // ──────────────────────────────────────────────────────
    static string awsTimestamp()
    {
        auto t = Clock.currTime(UTC());
        return "%04d%02d%02dT%02d%02d%02dZ".format(
            t.year, cast(int) t.month, t.day,
            t.hour, t.minute, t.second);
    }

    static string awsDate(string timestamp) { return timestamp[0 .. 8]; }

    static ubyte[] hmacSHA256(ubyte[] key, string msg)
    {
        return hmac!SHA256(cast(ubyte[]) msg, key).dup;
    }

    static string hexOf(ubyte[] data)
    {
        return toHexString!(LetterCase.lower)(data).idup;
    }

    ubyte[] signingKey(string dateStamp)
    {
        auto kDate    = hmacSHA256(cast(ubyte[])("AWS4" ~ sakId), dateStamp);
        auto kRegion  = hmacSHA256(kDate,    region);
        auto kService = hmacSHA256(kRegion,  "s3");
        return           hmacSHA256(kService, "aws4_request");
    }

    void signRequest(ref HTTP http, string method,
                     string canonicalUri, string queryString, string bodyHash)
    {
        if (bodyHash.length == 0)
            bodyHash = hexOf(sha256Of("").dup);

        string timestamp = awsTimestamp();
        string dateStamp = awsDate(timestamp);
        string host      = endpoint
            .replace("https://", "")
            .replace("http://",  "");

        string canonicalHeaders =
            "host:%s\n".format(host) ~
            "x-amz-content-sha256:%s\n".format(bodyHash) ~
            "x-amz-date:%s\n".format(timestamp);

        string signedHeaders = "host;x-amz-content-sha256;x-amz-date";

        string canonicalRequest = [
            method, canonicalUri, queryString,
            canonicalHeaders, signedHeaders, bodyHash
        ].join("\n");

        string credentialScope = "%s/%s/s3/aws4_request".format(dateStamp, region);

        string stringToSign = [
            "AWS4-HMAC-SHA256", timestamp, credentialScope,
            hexOf(sha256Of(canonicalRequest).dup)
        ].join("\n");

        string signature = hexOf(hmacSHA256(signingKey(dateStamp), stringToSign));

        http.addRequestHeader("Host",                 host);
        http.addRequestHeader("x-amz-date",           timestamp);
        http.addRequestHeader("x-amz-content-sha256", bodyHash);
        http.addRequestHeader("Authorization",
            "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
            .format(akId, credentialScope, signedHeaders, signature));
    }
    // ── Строит канонический query string по правилам AWS Sig V4 ──
    // Параметры сортируются по имени, ключи и значения URI-кодируются
    private static string buildCanonicalQuery(string[string] params)
    {
        import std.algorithm : sort;

        // Собираем и сортируем ключи
        string[] keys = params.keys;
        sort(keys);

        auto result = appender!string();
        bool first = true;
        foreach (k; keys)
        {
            if (!first) result ~= "&";
            first = false;
            result ~= uriEncodeQuery(k);
            result ~= "=";
            result ~= uriEncodeQuery(params[k]);
        }
        return result.data;
    }
}
