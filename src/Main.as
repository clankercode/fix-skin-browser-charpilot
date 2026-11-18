// Fix Skin Browser Char Pilot
//
// The Garage's skin browser previews every focused skin on a CarSport model
// (BrowserAPI.Script.txt FocusSkin hardcodes Const::C_CameraSkinModel), so skins
// from Skins/Models/CharacterPilot/ render broken. Nadeo's own pilot rendering
// (Garage.Script.txt C_Tab_Pilot) shows the right recipe: a CharacterPilot item in
// a menu scene with the skin as ItemCreate's name.
//
// This plugin cannot change FocusSkin (it is compiled into the game's manialink
// paks), so it shadows it: it watches the browser's controls read-only, and when a
// CharacterPilot skin is focused it hides the game's broken preview camera and
// renders the same pilot the Garage pilot tab does, in an owned UI layer placed
// exactly over the game's preview camera rect.
// Settings
[Setting name="Enabled" description="Show a proper CharacterPilot preview in the Garage skin browser (the game previews every skin on a CarSport model, so pilot skins render broken)."]
bool Setting_Enabled = true;
[Setting name="Turntable" description="Slowly rotate the previewed pilot (matches the Garage pilot tab)."]
bool Setting_Turntable = true;
[Setting name="Preview FOV" min=10.f max=90.f description="Preview camera field of view (degrees)."]
float Setting_Fov = 30.f;
[Setting name="Debug dump" description="Dump the skin browser's live label values and geometry to the Openplanet log while the browser is open."]
bool Setting_DebugDump = false;
[Setting name="Dev test open" description="DEV: open the preview with a hardcoded pilot skin whenever a browser layer is present, ignoring focus. Lets the layer be exercised via SetPluginSetting without menu input."]
bool Setting_DevTestOpen = false;
[Setting name="Dev layer type" description="DEV: CGameUILayer::EUILayerType for the overlay layer (0=Normal 1=ScoresTable 2=ScreenIn3d 3=AltMenu 4=Markers 5=CutScene 6=InGameMenu 7=EditorPlugin 8=ManiaplanetPlugin 9=ManiaplanetMenu 10=LoadingScreen). Layer is recreated on change."]
int Setting_DevLayerType = 0;
[Setting name="My Skins camera height" description="Garage My Skins pilot preview: camera height (m)."]
float Setting_MsCamY = 2.2;
[Setting name="My Skins camera distance" description="Garage My Skins pilot preview: camera z (negative = in front)."]
float Setting_MsCamZ = -14.0;
[Setting name="My Skins camera pitch" description="Garage My Skins pilot preview: camera pitch (degrees)."]
float Setting_MsCamPitch = 3.0;
[Setting name="My Skins camera FOV" description="Garage My Skins pilot preview: field of view (degrees)."]
float Setting_MsCamFov = 24.0;
[Setting name="Dev camera z-index" description="DEV: z-index of the overlay's sub-rect camera (needs to beat the browser frame's)."]
float Setting_DevCamZ = 50.0;
[Setting name="Dev rect x" description="DEV: override the dev-test overlay rect centre x (manialink units, page is 320x180 centred)."]
float Setting_DevRectX = 51.0;
[Setting name="Dev rect y" description="DEV: override the dev-test overlay rect centre y."]
float Setting_DevRectY = -33.0;
[Setting name="Dev rect w" description="DEV: override the dev-test overlay rect width."]
float Setting_DevRectW = 80.0;
[Setting name="Dev rect h" description="DEV: override the dev-test overlay rect height."]
float Setting_DevRectH = 75.0;

namespace FSB {
    bool g_debugDump = false;
    uint g_lastDump = 0;
    uint g_missed = 0;          // consecutive ticks without a focused pilot skin
    string g_lastLoggedSkin = "~none~";

    // Strip leading/trailing slashes after normalizing separators.
    string TrimSlashes(const string &in s) {
        string t = s.Replace("\\", "/");
        while (t.Length > 0 && t.StartsWith("/")) t = t.SubStr(1);
        while (t.Length > 0 && t.EndsWith("/")) t = t.SubStr(0, t.Length - 1);
        return t;
    }

    // Reconstruct the focused skin file as an ItemCreate skin name (backslash
    // form relative to the user game folder, e.g. "Skins\Models\CharacterPilot\
    // Gigachad.zip" — the format proven by pilot-preview's CheckSkin and matching
    // C_PilotDefaultSkinName "Skins/Models/CharacterPilot/Stadium.zip").
    // The browser's exact path-label format is not assumed: candidates are checked
    // against the user folder, and the folder-based candidate wins even when the
    // file is not locally visible (title-provided skins).
    string ResolvePilotSkinFile(const string &in folder, const string &in skinName) {
        if (skinName.Length == 0) return "";
        string f = TrimSlashes(folder);
        string[] candidates;
        if (f.Length > 0) candidates.InsertLast("Skins/" + f + "/" + skinName);
        candidates.InsertLast("Skins/Models/CharacterPilot/" + skinName);
        for (uint i = 0; i < candidates.Length; i++) {
            if (IO::FileExists(IO::FromUserGameFolder(candidates[i]))) {
                return candidates[i].Replace("/", "\\");
            }
        }
        if (f.Length > 0) return ("Skins/" + f + "/" + skinName).Replace("/", "\\");
        return "";
    }

    Rect@ RectFromState(BrowserState@ st) {
        Rect@ r = Rect();
        r.x = st.camAbsPos.x;
        r.y = st.camAbsPos.y;
        r.w = st.camSize.x;
        r.h = st.camSize.y;
        return r;
    }

    void DumpState(BrowserState@ st) {
        string live = "";
        if (g_attachId.Length > 0) {
            auto layer = FindLayer(OwnerMenu(), g_attachId);
            auto root = RootOf(layer);
            live = " layer[status=" + Out(root, "status") + " ready=" + Out(root, "ready")
                + " manager=" + Out(root, "manager") + " ack=" + Out(root, "ack")
                + " scene=" + Out(root, "scene") + " pilot=" + Out(root, "pilot")
                + " did=" + Out(root, "did") + " skinIn=" + Out(root, "skin")
                + " err=" + Out(root, "err")
                + " myType=" + (layer !is null ? tostring(layer.Type) : "?")
                + " running=" + (layer !is null && layer.IsLocalPageScriptRunning ? "1" : "0")
                + " visible=" + (layer !is null && layer.IsVisible ? "1" : "0")
                + " gameCamVisible=" + (st.gameCamVisible ? "1" : "0") + "]";
        }
        print("[FixSkinBrowserCharPilot] browser state:"
            + " folder='" + st.folder + "'"
            + " skin='" + st.skinName + "'"
            + " zipFocused=" + (st.zipFocused ? "1" : "0")
            + " pilotFolder=" + (st.pilotFolder ? "1" : "0")
            + " camAbs=" + int(st.camAbsPos.x) + "," + int(st.camAbsPos.y)
            + " camChain=" + int(st.camChainPos.x) + "," + int(st.camChainPos.y)
            + " size=" + int(st.camSize.x) + "x" + int(st.camSize.y)
            + " bType=" + st.browserLayerType + " bParentVis=" + (st.browserParentVisible ? "1" : "0")
            + live);
    }

    bool ShouldRun(BrowserState@ st) {
        if (!Setting_Enabled) return false;
        // browserParentVisible = Frame_Global.Parent.Visible — the same signal
        // BrowserAPI itself gates FocusSkin on; labels persist stale after the
        // browser closes, so they alone cannot decide "focused".
        return st.valid && st.zipFocused && st.pilotFolder && st.browserParentVisible;
    }

    // What the overlay should show this tick. Filled by whichever source owns the
    // preview (skin browser > garage My Skins > dev test); empty skinName = nothing.
    class Want {
        string source;          // "browser" | "myskins" | "dev"
        string skinName;        // ItemCreate name (local "Skins\..." path, or NS skin Name)
        string skinUrl;         // ItemCreate url ("" for local files)
        Rect@ rect;
        // Camera: browser-rect framing vs garage framing (Garage.Script.txt:1109-1112)
        vec3 cam = vec3(0, 1.0, -5.5);
        float camPitch = 2.0;
        float camFov = 30.0;
    }

    // Garage My Skins: the camera control is the garage's fullscreen one, offset by
    // frame-camera.RelativePosition_V3 (Pos_CameraMySkins = <30., 12.>); camera
    // location/FOV are the garage pilot-tab values (C_CameraPosition, C_CameraRotation,
    // C_CameraFOVPilot).
    uint g_lastMsDump = 0;
    Want@ WantFromMySkins(CGameManiaApp@ owner) {
        auto ms = MySkinsState();
        bool ok = ReadMySkinsState(owner, ms);
        if (g_debugDump && Time::Now - g_lastMsDump > 2000) {
            g_lastMsDump = Time::Now;
            print("[FixSkinBrowserCharPilot] myskins: read=" + ok + " tabVisible=" + ms.tabVisible + " focused='" + ms.focusedName
                + "' camOff=" + ms.cameraOffset.x + "," + ms.cameraOffset.y + " favs=" + g_favs.Length + " dbg=" + ms.debug);
        }
        bool onTab = ok && ms.tabVisible;
        // Fetch the favourite list once per visit to the tab (the garage itself
        // refetches on entry, so this mirrors its traffic), not on a timer.
        if (onTab && !g_wasOnMySkins) g_favsStale = true;
        g_wasOnMySkins = onTab;
        if (!onTab || ms.focusedName.Length == 0) return null;
        if (g_favsStale && !g_favsFetching) {
            g_favsStale = false;
            FetchFavourites();
        }
        auto fav = FindFav(ms.focusedName);
        if (fav is null) {
            // Unknown name (e.g. favourited after our fetch): one rate-limited refetch.
            if (Time::Now - g_favsFetchedAt > 15000) g_favsStale = true;
            return null;
        }
        if (!IsPilotType(fav.type)) return null;
        string local = LocalPilotPreview(fav.name, fav.fileUrl);
        if (local.Length == 0) return null;
        Want@ w = Want();
        w.source = "myskins";
        w.skinName = local;
        @w.rect = Rect();
        w.rect.fullscreen = true;
        w.rect.x = ms.cameraFound ? ms.cameraOffset.x : 30.0;
        w.rect.y = ms.cameraFound ? ms.cameraOffset.y : 12.0;
        // The garage's car camera (<0,2.3,-10>, 9°, FOV 20) puts a standing pilot's
        // head above the tab bar in the My Skins framing; pull back and level out so
        // the whole pilot stands where the car was. Tunable via the dev settings.
        w.cam = vec3(0, Setting_MsCamY, Setting_MsCamZ);
        w.camPitch = Setting_MsCamPitch;
        w.camFov = Setting_MsCamFov;
        return w;
    }

    Want@ WantFromBrowser(BrowserState@ st) {
        if (!ShouldRun(st)) return null;
        string skinFile = ResolvePilotSkinFile(st.folder, st.skinName);
        if (skinFile.Length == 0) return null;
        Want@ w = Want();
        w.source = "browser";
        w.skinName = skinFile;
        @w.rect = RectFromState(st);
        // Keep clear of the browser's title label (label-skin, top of the frame,
        // z 5 — our camera must draw above the panel, so it would cover the title).
        const float titleBand = 17.0;
        w.rect.h -= titleBand;
        w.rect.y -= titleBand * 0.5;
        w.cam = vec3(0, 0.95, -5.0);
        w.camPitch = 3.0;
        w.camFov = Setting_Fov;
        return w;
    }

    Want@ WantFromDev() {
        Want@ w = Want();
        w.source = "dev";
        w.skinName = "Skins\\Models\\CharacterPilot\\Miku-Skin.zip";
        @w.rect = Rect();
        w.rect.x = Setting_DevRectX; w.rect.y = Setting_DevRectY;
        w.rect.w = Setting_DevRectW; w.rect.h = Setting_DevRectH;
        w.camFov = Setting_Fov;
        return w;
    }

    string g_liveKey = "";   // source|name|url the live layer is showing
    string g_liveCamKey = "";

    // Open (once per change) or keep alive the overlay for w. Yields.
    void ApplyWant(CGameManiaApp@ owner, Want@ w) {
        string key = w.source + "|" + w.skinName + "|" + w.skinUrl;
        if (key != g_lastLoggedSkin) {
            g_lastLoggedSkin = key;
            g_liveKey = ""; // new skin: full reopen (scene recreated with camera visible)
            print("[FixSkinBrowserCharPilot] focused skin -> '" + w.skinName + "' (" + w.source + (w.skinUrl.Length > 0 ? ", url" : "") + ")");
        }
        try {
            auto root = EnsureLayer(w.rect, Setting_DevLayerType);
            InF(root, "beat", float(Time::Now % 1000000));
            bool fresh = Out(root, "scene").Length == 0;
            string camKey = Text::Format("%.2f", w.cam.y) + "," + Text::Format("%.2f", w.cam.z) + "," + Text::Format("%.2f", w.camPitch) + "," + Text::Format("%.2f", w.camFov);
            if (!fresh && key == g_liveKey && camKey != g_liveCamKey) {
                // Camera-only change (settings tuning): re-place the camera, keep the pilot.
                g_liveCamKey = camKey;
                InF(root, "camx", w.cam.x);
                InF(root, "camy", w.cam.y);
                InF(root, "camz", w.cam.z);
                InF(root, "campitch", w.camPitch);
                InF(root, "camfov", w.camFov);
                Run(root, "camera");
            }
            if (fresh || key != g_liveKey) {
                // Hide the game's preview cameras BEFORE our SceneCreate: a new scene
                // binds to a camera that is visible at creation time, and the game
                // re-Shows its own on every focus change.
                // Both, whatever the source: a camera whose own Visible is true binds a
                // new scene even when an ancestor frame hides it (e.g. the garage's
                // camera-skin while the browser is open), and the pilot is then lost.
                SetGameCameraVisible(owner, false);
                SetGarageCameraVisible(owner, false);
                yield();
                g_liveCamKey = camKey;
                g_liveKey = key;
                g_pilotSkin = w.skinName;
                In(root, "pilotskin", w.skinName);
                In(root, "piloturl", w.skinUrl);
                InB(root, "turntable", Setting_Turntable);
                InB(root, "applycam", true);
                InF(root, "camx", w.cam.x);
                InF(root, "camy", w.cam.y);
                InF(root, "camz", w.cam.z);
                InF(root, "campitch", w.camPitch);
                InF(root, "camfov", w.camFov);
                InF(root, "pilotangle", 0.0);
                InB(root, "forcepilot", true);
                Run(root, "open");
                InB(root, "forcepilot", false);
                if (g_debugDump) print("[FixSkinBrowserCharPilot] opened: did=" + Out(root, "did") + " err=" + Out(root, "err"));
            }
            // The game's preview (a CarSport that cannot show this skin) is redundant;
            // the browser re-Shows its camera on every focus change, so re-assert.
            if (w.source == "browser") SetGameCameraVisible(owner, false);
            else if (w.source == "myskins") SetGarageCameraVisible(owner, false);
        } catch {
            warn("[FixSkinBrowserCharPilot] open failed: " + getExceptionInfo());
            g_liveKey = "";
            g_pilotSkin = "";
        }
    }

    // One monitor step. Returns false when the menu is not available at all.
    bool MonitorTick() {
        auto owner = OwnerMenu();
        if (owner is null) {
            CancelPilotDownload();
            if (g_attachId.Length > 0) CloseLive(false);
            g_liveKey = "";
            return false;
        }
        g_debugDump = Setting_DebugDump;
        auto st = BrowserState();
        bool found = ReadBrowserState(owner, st);
        if (g_debugDump && found && Time::Now - g_lastDump > 2000) {
            g_lastDump = Time::Now;
            DumpState(st);
        }
        Want@ w = null;
        g_downloadWanted = false;
        if (Setting_Enabled) {
            if (found) @w = WantFromBrowser(st);
            // The browser is an overlay on the garage; while it is open it owns the preview.
            if (w is null && !(found && st.browserParentVisible)) @w = WantFromMySkins(owner);
        }
        if (!g_downloadWanted) CancelPilotDownload();
        if (w is null && Setting_DevTestOpen) @w = WantFromDev();
        if (w !is null) {
            g_missed = 0;
            ApplyWant(owner, w);
            return true;
        }
        // Allow one missed sample during a carousel refresh, but don't keep the
        // previous pilot on screen while the user is on a different control.
        if (g_attachId.Length > 0 && ++g_missed > 1) {
            g_missed = 0;
            SetGameCameraVisible(owner, true);
            SetGarageCameraVisible(owner, true);
            CloseLive(true);
            g_liveKey = "";
        }
        return true;
    }

    void MonitorLoop() {
        while (!g_stopping) {
            DevNavTick();
            MonitorTick();
            sleep(150);
        }
    }

    void Shutdown() {
        g_stopping = true;
        CancelPilotDownload();
        // Unload cannot yield: ask the layer script to tear its scene down itself
        // (it does so on i-retire, and also after 10 s without a heartbeat), and
        // remove every layer of ours that holds no scene. A retiring layer is left
        // hidden and empty; the next plugin load sweeps it.
        SetGameCameraVisible(OwnerMenu(), true);
        SetGarageCameraVisible(OwnerMenu(), true);
        CloseLive(false);
        SweepStale(OwnerMenu());
    }
}

void Main() {
    print("[FixSkinBrowserCharPilot] Main() v5: monitor starting");
    startnew(FSB::MonitorLoop);
}

void OnDisabled() { FSB::Shutdown(); }
void OnDestroyed() { FSB::Shutdown(); }
