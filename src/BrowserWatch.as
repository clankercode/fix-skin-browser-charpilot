// Read-only detection of the in-game skin browser state.
//
// The browser (BrowserAPI.Script.txt embedded in the Garage page) stores the
// focused file path in ManiaScript-only `declare ... for` variables, which
// AngelScript cannot read. But FocusSkin() writes what we need onto ordinary
// controls, and those are readable from AngelScript via the menu ManiaApp's
// UILayers:
//   - camera-skin.Visible     = a browser element is focused (set by FocusSkin)
//   - label-skin (CGameManialinkLabel.Value) = focused file name, "" when none
//   - label-path (CGameManialinkLabel.Value) = current folder (SetPathLabelValue)
//
// Label values are read via Dev::GetOffsetString on the reflected `Value` member,
// the same technique tm-control-mcp uses (ManialinkIntrospection.as
// _ReadLabelValue), to avoid wstring property access from AngelScript.
namespace FSB {
    const string IdFrameGlobal = "trackmania-browser-api_frame-global";
    const string IdCameraSkin = "trackmania-browser-api_camera-skin";
    const string IdLabelPath = "trackmania-browser-api_label-path";
    const string IdLabelSkin = "trackmania-browser-api_label-skin";

    class BrowserState {
        bool valid;            // an open skin browser instance was found
        bool zipFocused;       // a .zip skin element is focused (game preview camera visible + name label non-empty)
        bool pilotFolder;      // current folder looks like CharacterPilot
        string folder;         // raw label-path value ("" when at the browser root)
        string skinName;       // raw label-skin value, e.g. "MyPilot.zip"
        vec2 camAbsPos;        // camera-skin AbsolutePosition_V3 (page space)
        vec2 camSize;          // camera-skin Size
        vec2 camChainPos;      // sum of RelativePosition_V3 up the parent chain (cross-check for camAbsPos)
        bool gameCamVisible;   // game preview camera Visible flag as read this tick
        int browserLayerType;  // CGameUILayer::EUILayerType of the candidate layer
        bool browserParentVisible; // Frame_Global.Parent.Visible — BrowserAPI's own browser-open signal
    }

    string ReadLabelValue(CGameManialinkControl@ ctrl) {
        if (ctrl is null) return "";
        auto lbl = cast<CGameManialinkLabel>(ctrl);
        if (lbl is null) return "";
        try {
            auto ty = Reflection::TypeOf(lbl);
            if (ty is null) return "";
            auto m = ty.GetMember("Value");
            if (m is null || m.Offset >= 0xFFFF) return "";
            return Dev::GetOffsetString(lbl, m.Offset);
        } catch { /* swallow */ }
        return "";
    }

    vec2 SumParentOffsets(CGameManialinkControl@ leaf) {
        vec2 p = vec2(0, 0);
        CGameManialinkControl@ c = leaf;
        while (c !is null) {
            p += c.RelativePosition_V3;
            @c = c.Parent;
        }
        return p;
    }

    // Find the open skin browser and read its state.
    // Returns false when no browser is present at all. Several pages embed
    // BrowserAPI (same control ids), and a hidden page's browser root frame still
    // reports Visible (the overlay visibility lives on the parent), so candidates
    // are ranked: a layer whose preview camera is actually showing a focused .zip
    // wins; otherwise the first candidate is reported (valid, not focused).
    bool ReadBrowserState(CGameManiaApp@ owner, BrowserState@ s) {
        s.valid = false;
        s.zipFocused = false;
        s.pilotFolder = false;
        s.folder = "";
        s.skinName = "";
        if (owner is null) return false;
        bool haveAny = false;
        for (uint i = 0; i < owner.UILayers.Length; i++) {
            auto l = owner.UILayers[i];
            if (l is null || l.LocalPage is null) continue;
            auto frameGlobal = l.LocalPage.GetFirstChild(IdFrameGlobal);
            if (frameGlobal is null) continue;
            auto cam = l.LocalPage.GetFirstChild(IdCameraSkin);
            if (cam is null) continue;
            BrowserState@ cand = BrowserState();
            cand.folder = ReadLabelValue(l.LocalPage.GetFirstChild(IdLabelPath));
            cand.skinName = ReadLabelValue(l.LocalPage.GetFirstChild(IdLabelSkin));
            cand.camAbsPos = cam.AbsolutePosition_V3;
            cand.camSize = cam.Size;
            cand.camChainPos = SumParentOffsets(cam);
            cand.gameCamVisible = cam.Visible;
            cand.browserLayerType = l.Type;
            // BrowserAPI gates FocusSkin on Frame_Global.Parent.Visible, but the
            // garage closes the browser by hiding its frame-browser instance further
            // up, so the whole ancestor chain has to be visible (verified 2026-11-18:
            // the parent alone stayed Visible after the browser closed).
            bool chainVisible = frameGlobal.Visible;
            auto anc = frameGlobal.Parent;
            while (chainVisible && anc !is null) { chainVisible = anc.Visible; @anc = anc.Parent; }
            cand.browserParentVisible = chainVisible;
            string nameLower = cand.skinName.ToLower();
            // Do NOT gate on cam.Visible: the game re-Shows its preview camera on
            // every FocusSkin, and we Hide() it while our overlay runs — gating on
            // visibility here makes detection flip with our own hide/restore cycle.
            cand.zipFocused = nameLower.Length > 4 && nameLower.EndsWith(".zip");
            cand.pilotFolder = cand.folder.ToLower().Contains("characterpilot");
            cand.valid = true;
            haveAny = true;
            if (cand.zipFocused) {
                s = cand;
                return true;
            }
            if (!s.valid) s = cand;
            if (Setting_DebugDump && cam.Visible) {
                print("[FixSkinBrowserCharPilot] candidate layer " + i + ": folder='" + cand.folder + "' skin='" + cand.skinName + "' camVisible=1");
            }
        }
        return haveAny;
    }

    // Show()/Hide() the game's own preview camera. While our overlay shows a pilot
    // we hide it (its scene holds a CarSport that cannot load the pilot skin); when
    // we close, we restore it — FocusSkin overwrites it on the next focus event
    // anyway, so a stale restore is harmless. Several pages embed BrowserAPI with
    // the same control ids, so every layer that has the camera is handled.
    void SetGameCameraVisible(CGameManiaApp@ owner, bool visible) {
        if (owner is null) return;
        for (uint i = 0; i < owner.UILayers.Length; i++) {
            auto l = owner.UILayers[i];
            if (l is null || l.LocalPage is null) continue;
            auto frameGlobal = l.LocalPage.GetFirstChild(IdFrameGlobal);
            if (frameGlobal is null) continue;
            auto cam = l.LocalPage.GetFirstChild(IdCameraSkin);
            if (cam is null) continue;
            if (visible) cam.Show(); else cam.Hide();
        }
    }
}
