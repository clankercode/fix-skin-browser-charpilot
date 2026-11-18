namespace FSB {
    const string PILOT_CACHE_DIR = "Skins/Models/CharacterPilot/FixSkinBrowserCache";
    const string SKIN_CDN = "https://core.trackmania.nadeo.live/storageObjects/";
    const int64 MAX_PILOT_BYTES = 32 * 1024 * 1024;
    Net::HttpRequest@ g_pilotDownload;
    string g_downloadUrl;
    uint64 g_downloadDeadline;
    uint64 g_downloadRetryAt;
    bool g_downloadWanted;

    void CancelPilotDownload() {
        if (g_pilotDownload !is null && !g_pilotDownload.Finished()) g_pilotDownload.Cancel();
        @g_pilotDownload = null;
    }

    string LocalPilotPreview(const string &in name, const string &in url) {
        string rel = name.Replace("\\", "/");
        if (rel.StartsWith("Skins/Models/CharacterPilot/") && !rel.Contains("../")
                && IO::FileExists(IO::FromUserGameFolder(rel))) return name;

        // The menu's CharacterPilot ItemCreate doesn't fetch this URL itself.
        // Only fetch from the game's skin service, and respect skin download settings.
        auto app = cast<CTrackMania>(GetApp());
        auto config = app is null ? null : app.SystemConfig;
        if (config is null || config.IsIgnorePlayerSkins || !config.FileTransferEnableVehicleSkinDownload
                || !url.StartsWith(SKIN_CDN)) return "";

        string cached = PILOT_CACHE_DIR + "/fsb-" + Crypto::MD5(url) + ".zip";
        string path = IO::FromUserGameFolder(cached);
        if (IO::FileExists(path)) return cached.Replace("/", "\\");
        g_downloadWanted = true;
        if (url != g_downloadUrl) {
            CancelPilotDownload();
            g_downloadUrl = url;
            g_downloadRetryAt = 0;
        }
        if (g_pilotDownload is null) {
            if (Time::Now < g_downloadRetryAt) return "";
            @g_pilotDownload = Net::HttpRequest();
            g_pilotDownload.Url = url;
            g_pilotDownload.Method = Net::HttpMethod::Get;
            // Nadeo's storageObjects route redirects to its object CDN.
            g_pilotDownload.Redirect = true;
            g_downloadDeadline = Time::Now + 20000;
            g_pilotDownload.Start();
            return "";
        }
        bool finished = g_pilotDownload.Finished();
        if (!finished && Time::Now < g_downloadDeadline
                && g_pilotDownload.ProgressDownload() <= MAX_PILOT_BYTES) return "";
        auto req = g_pilotDownload;
        @g_pilotDownload = null;

        string tmp = path + ".part";
        try {
            if (!finished) {
                req.Cancel();
                throw("timeout or size limit");
            }
            int code = req.ResponseCode();
            if (code != 200) throw("HTTP " + code);
            // Buffer() takes the response. Don't query request state after it.
            auto bytes = req.Buffer();
            if (bytes is null || bytes.GetSize() < 30 || bytes.GetSize() > uint64(MAX_PILOT_BYTES)) throw("invalid ZIP size");
            bytes.Seek(0);
            if (bytes.ReadUInt32() != 0x04034B50) throw("response is not a ZIP");
            bytes.Seek(0);
            IO::CreateFolder(IO::FromUserGameFolder(PILOT_CACHE_DIR), true);
            IO::File outFile(tmp, IO::FileMode::Write);
            outFile.Write(bytes);
            outFile.Close();
            auto folder = Fids::GetUserFolder("Skins/Models/CharacterPilot");
            if (folder is null) throw("pilot folder not available");
            IO::Move(tmp, path);
            Fids::UpdateTree(folder, true);
            if (g_debugDump) print("[FixSkinBrowserCharPilot] cached uploaded pilot '" + name + "'");
            return cached.Replace("/", "\\");
        } catch {
            // Do not log exceptions from the HTTP API: they can contain the signed URL.
            warn("[FixSkinBrowserCharPilot] could not cache uploaded pilot '" + name + "'");
            if (IO::FileExists(tmp)) IO::Delete(tmp);
            g_downloadRetryAt = Time::Now + 30000;
        }
        return "";
    }
}
