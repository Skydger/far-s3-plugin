# S3 Navigator

A Far Manager 3 panel plugin for browsing and downloading files from S3-compatible object storage (AWS S3, MinIO, Yandex Object Storage and anything else that speaks the same API).

Русская версия: [README.md](README.md).

## Features

- Multiple connection profiles, each with its own endpoint, keys, region and default bucket
- Bucket list and object listing with virtual folders (CommonPrefixes)
- Download single files or whole folder trees, keeping the subdirectory structure
- Conflict dialog on existing local files: overwrite / skip / rename / append / cancel, with a "remember for all" option
- Download progress: per-file and total bars in a dialog, plus the taskbar progress indicator
- Profile editor, duplicate, rename and delete from the panel
- Settings stored as JSON in the Far profile; old config format is migrated automatically
- AWS Signature V4 request signing
- HEAD requests used to show size and checksum (CRC32 or MD5/ETag) before downloading
- Debug logging to a file in the Far profile when built with the debug build type

## Keys

In the profiles list:

| Key | Action |
|---|---|
| F4 | Edit connection |
| Shift+F4 | New connection |
| Shift+F5 | Duplicate connection |
| Shift+F6 | Rename connection |
| F8 / Delete | Delete connection |
| Shift+F9 | Save settings |

## Building

Written in D, built with [DUB](https://code.dlang.org/) and the
[far3api](https://code.dlang.org/packages/far3api) package (3.0.6116).
Native libraries: curl, shell32, ole32.

```
dub build              # debug
dub build -b release   # release, binary goes to bin/rls/
```

The result is `far_s3.dll`. Drop it into a Far Manager plugins folder, for
example `%FARPROFILE%\Plugins\S3Navigator\`, restart Far, then pick
"S3 Navigator" from the plugins menu (F11) or the disks menu (Alt+F1/Alt+F2).

## Configuration

Settings live at
`%LOCALAPPDATA%\Far Manager\Profile\PluginsData\far-s3-navigator\settings.json`:

```json
{
  "profiles": [
    {
      "name": "My S3",
      "endpoint": "https://s3.example.com",
      "bucket": "my-bucket",
      "accessKeyId": "AKIA...",
      "secretKey": "...",
      "region": "us-east-1"
    }
  ]
}
```

Leave `bucket` empty to be shown the bucket list on connect. Region defaults to
`us-east-1`.

## Debugging

Debug builds write a log to
`%LOCALAPPDATA%\Far Manager\Profile\PluginsData\far-s3-navigator\s3navigator.log`.

## License

MIT. See [LICENSE](LICENSE). Author: Skydger.
