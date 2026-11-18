// Garage > MY SKINS carousel: the focused favourite skin is previewed on a CarSport
// (Garage.Script.txt DisplayScene, C_Tab_MySkins branch, :1460-1497) even when its
// NadeoServices Type is "Models/CharacterPilot". The garage never branches on Type.
//
// Read-only detection (verified on tm7 2026-11-18 with tm-control-mcp):
//   - frame-tab-my-skins.Visible           = the MY SKINS tab is showing
//   - button-my-skin-N / quad-button-delete = Show()n only on the focused button
//     (Garage FocusSkin; every other button Hide()s it)
//   - button-my-skin-N / ... / cmgame-control-block-list_label-content
//                                           = that skin's DisplayName
// The skin's Type, Name and FileUrl come from the same NadeoServices favourite list
// the garage loads (DataFileMgr.AccountSkin_NadeoServices_GetFavoriteList), fetched
// here from AngelScript (precedent: tm-spike-custom-skins AccountSkin.as).
namespace FSB {
    const string IdTabMySkins = "frame-tab-my-skins";
    const string IdMySkinButtonPrefix = "button-my-skin-";
    const string IdDeleteQuad = "quad-button-delete";
    const string IdBlockListLabel = "cmgame-control-block-list_label-content";
    const string IdGarageCamera = "frame-camera";
    const uint MY_SKIN_BUTTONS = 8; // Garage.Script.txt:416-449 generates keys 0..7

    class FavSkin {
        string displayName;
        string name;
        string type;
        string fileUrl;
    }

    FavSkin@[] g_favs;
    uint64 g_favsFetchedAt = 0;
    bool g_favsFetching = false;
    bool g_favsStale = true;     // fetch on next need
    bool g_wasOnMySkins = false; // My Skins tab visible last tick (entry edge -> refetch)

    class MySkinsState {
        bool tabVisible = false;
        string focusedName = "";      // DisplayName on the focused carousel button
        vec2 cameraOffset;            // garage frame-camera RelativePosition_V3
        bool cameraFound = false;
        string debug = "";            // where detection stopped (DebugDump)
    }

    CGameManialinkControl@ FindInLayers(CGameManiaApp@ owner, const string &in id, CGameUILayer@ &out layerOut) {
        @layerOut = null;
        for (uint i = 0; i < owner.UILayers.Length; i++) {
            auto l = owner.UILayers[i];
            if (l is null || l.LocalPage is null) continue;
            auto c = l.LocalPage.GetFirstChild(id);
            if (c !is null) { @layerOut = l; return c; }
        }
        return null;
    }

    // Frame.GetFirstChild does not descend into frameinstance (component) subtrees:
    // the name label is button-my-skin-N/#0/control-block-list-name/#0/<label>
    // (tm-control-mcp FindControlsByLabel path). Walk Controls explicitly.
    string FindLabelBelow(CGameManialinkControl@ c, const string &in id, int depth) {
        if (c is null || depth < 0) return "";
        if (c.ControlId == id) return ReadLabelValue(c);
        auto f = cast<CGameManialinkFrame>(c);
        if (f is null) return "";
        for (uint i = 0; i < f.Controls.Length; i++) {
            string v = FindLabelBelow(f.Controls[i], id, depth - 1);
            if (v.Length > 0) return v;
        }
        return "";
    }

    bool ReadMySkinsState(CGameManiaApp@ owner, MySkinsState@ s) {
        if (owner is null) return false;
        CGameUILayer@ layer;
        auto tab = FindInLayers(owner, IdTabMySkins, layer);
        if (tab is null || layer is null) { s.debug = "no-tab"; return false; }
        if (!layer.IsVisible) { s.debug = "layer-hidden"; return false; }
        // The garage page layer stays allocated when the route changes; it is the
        // visibility up the chain that tells whether the tab is really on screen.
        bool visible = tab.Visible;
        string chain = visible ? "t1" : "t0";
        auto p = tab.Parent;
        while (visible && p !is null) { visible = p.Visible; chain += visible ? "1" : "0"; @p = p.Parent; }
        s.tabVisible = visible;
        s.debug = "chain=" + chain;
        auto cam = layer.LocalPage.GetFirstChild(IdGarageCamera);
        if (cam !is null) { s.cameraOffset = cam.RelativePosition_V3; s.cameraFound = true; }
        if (!s.tabVisible) return true;
        string btns = "";
        for (uint k = 0; k < MY_SKIN_BUTTONS; k++) {
            auto btn = cast<CGameManialinkFrame>(layer.LocalPage.GetFirstChild(IdMySkinButtonPrefix + k));
            if (btn is null) { btns += "n"; continue; }
            if (!btn.Visible) { btns += "h"; continue; }
            auto del = btn.GetFirstChild(IdDeleteQuad);
            if (del is null) { btns += "d"; continue; }
            if (!del.Visible) { btns += "."; continue; }
            btns += "F";
            if (s.focusedName.Length == 0) s.focusedName = FindLabelBelow(btn, IdBlockListLabel, 6);
        }
        s.debug += " btns=" + btns;
        return true;
    }

    // Fetch (or refresh) the favourite list. Yields; call from the monitor coroutine.
    void FetchFavourites() {
        if (g_favsFetching) return;
        g_favsFetching = true;
        CGameDataFileManagerScript@ mgr = null;
        // NB: the ManiaScript alias CTaskResult_NSSkinList is NOT the AngelScript
        // type name; the game compiler rejects it (the LSP did not, 2026-11-18).
        CWebServicesTaskResult_NadeoServicesSkinListScript@ task = null;
        try {
            auto owner = OwnerMenu();
            if (owner is null || owner.DataFileMgr is null || owner.UserMgr is null) throw("menu managers unavailable");
            @mgr = owner.DataFileMgr;
            MwId userId;
            if (owner.UserMgr.MainUser !is null) userId = owner.UserMgr.MainUser.Id;
            else if (owner.UserMgr.Users.Length > 0) userId = owner.UserMgr.Users[0].Id;
            else throw("no menu user");
            @task = mgr.AccountSkin_NadeoServices_GetFavoriteList(userId);
            if (task is null) throw("favourite list task unavailable");
            uint64 deadline = Time::Now + 15000;
            while (task.IsProcessing) {
                if (g_stopping || Time::Now > deadline) throw("favourite list timed out");
                yield();
            }
            if (!task.HasSucceeded) throw("favourite list failed: " + string(task.ErrorCode));
            FavSkin@[] favs;
            for (uint i = 0; i < task.SkinList.Length; i++) {
                auto ns = task.SkinList[i];
                if (ns is null) continue;
                FavSkin@ f = FavSkin();
                f.displayName = string(ns.DisplayName);
                f.name = string(ns.Name);
                f.type = string(ns.Type);
                f.fileUrl = string(ns.FileUrl);
                favs.InsertLast(f);
            }
            g_favs = favs;
            g_favsFetchedAt = Time::Now;
            print("[FixSkinBrowserCharPilot] favourite skins: " + g_favs.Length + " (pilot: " + CountPilotFavs() + ")");
        } catch {
            warn("[FixSkinBrowserCharPilot] favourite list: " + getExceptionInfo());
            g_favsFetchedAt = Time::Now; // back off; retry after the refresh interval
        }
        if (mgr !is null && task !is null) mgr.TaskResult_Release(task.Id);
        g_favsFetching = false;
    }

    // Garage's own fullscreen preview camera (Garage.Script.txt:772, id "camera-skin",
    // inside frame-camera). Hidden while our pilot owns the My Skins preview, else
    // the black CarSport keeps rendering behind/around the pilot. The garage itself
    // sets camera-skin.Visible in DisplayScene, so a stale restore is harmless.
    void SetGarageCameraVisible(CGameManiaApp@ owner, bool visible) {
        if (owner is null) return;
        CGameUILayer@ layer;
        auto frameCam = FindInLayers(owner, IdGarageCamera, layer);
        auto f = cast<CGameManialinkFrame>(frameCam);
        if (f is null) return;
        auto cam = f.GetFirstChild("camera-skin");
        if (cam is null) return;
        if (visible) cam.Show(); else cam.Hide();
    }

    uint CountPilotFavs() {
        uint n = 0;
        for (uint i = 0; i < g_favs.Length; i++) if (IsPilotType(g_favs[i].type)) n++;
        return n;
    }

    bool IsPilotType(const string &in t) {
        return t.ToLower().Contains("characterpilot");
    }

    // Labels may carry formatting codes ($i$t prefix is applied by the component,
    // not stored, but strip anything $-prefixed defensively) and case differs from
    // what the carousel displays ("SLENDERMAN" is $t-uppercased on screen only).
    string NormName(const string &in s) {
        return Text::StripFormatCodes(s).Trim().ToLower();
    }

    FavSkin@ FindFav(const string &in displayName) {
        string want = NormName(displayName);
        if (want.Length == 0) return null;
        for (uint i = 0; i < g_favs.Length; i++) {
            if (NormName(g_favs[i].displayName) == want) return g_favs[i];
        }
        return null;
    }
}
