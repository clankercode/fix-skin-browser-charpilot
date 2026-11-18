// DEV: in-game menu navigation without OS input.
//
// The menu ManiaApp forwards every nav key to the page layers as
//   LayerCustomEvent(layer, "ShareMenuNavigation_MenuNavigation",
//                    ["::EMenuNavAction::<Action>", isAutoRepeat, userIndex, isFromMouse])
// (MenuLibs/Common/Menu/ShareMenuNavigation.Script.txt:45-48, parsed at :100-118).
// Sending the same event from AngelScript drives Navigation-component pages
// (garage buttons, browser) exactly like a key press. OS-level injection does not
// reach TM (in-process SendInput: SDL raw input; XTEST: needs real focus).
//
// Trigger remotely: SetPluginSetting varName=Setting_DevNav value="Down" (or a
// comma list "Down,Down,Select"); actions are sent ~350 ms apart, then the setting
// is cleared.
[Setting hidden]
string Setting_DevNav = "";
// Optional guard for Select: the injection is refused unless the focused control's
// id or label contains this text (e.g. "button-upload", "CharacterPilot").
[Setting hidden]
string Setting_DevNavExpect = "";

namespace FSB {
    const string NavEventType = "ShareMenuNavigation_MenuNavigation";

    void SendNav(const string &in action) {
        auto owner = OwnerMenu();
        if (owner is null) return;
        string a = action.Trim();
        if (a.Length == 0) return;
        MwFastBuffer<wstring> data;
        data.Add(wstring("::EMenuNavAction::" + a));
        data.Add(wstring("false"));
        data.Add(wstring("0"));
        data.Add(wstring("false"));
        uint sent = 0;
        for (uint i = 0; i < owner.UILayers.Length; i++) {
            auto l = owner.UILayers[i];
            if (l is null || l.AttachId.StartsWith(ATTACH_PREFIX)) continue;
            owner.LayerCustomEvent(l, wstring(NavEventType), data);
            sent++;
        }
        print("[FixSkinBrowserCharPilot] devnav " + a + " -> " + sent + " layers");
    }

    // Describe every focused control (IsFocused) in the menu's page layers:
    // "<controlId>:<label text>" joined by '|'. Labels inside focused frames are
    // included so folder/file tiles (whose text lives in a child label) match.
    string FocusedDescr() {
        auto owner = OwnerMenu();
        if (owner is null) return "";
        string acc = "";
        for (uint i = 0; i < owner.UILayers.Length; i++) {
            auto l = owner.UILayers[i];
            if (l is null || l.LocalPage is null || !l.IsVisible) continue;
            if (l.AttachId.StartsWith(ATTACH_PREFIX)) continue;
            acc += CollectFocused(l.LocalPage.MainFrame, 12);
        }
        // Navigation-component focus is visual only (IsFocused stays false), so add the
        // page context this plugin already detects reliably: "browser:<folder>" while the
        // skin browser is open, else "myskins" while the garage My Skins tab is shown.
        auto bs = BrowserState();
        if (ReadBrowserState(owner, bs) && bs.browserParentVisible) return "browser:" + bs.folder + "|" + acc;
        auto ms = MySkinsState();
        if (ReadMySkinsState(owner, ms) && ms.tabVisible) return "myskins|" + acc;
        return acc;
    }

    string CollectFocused(CGameManialinkControl@ c, int depth) {
        if (c is null || depth < 0) return "";
        string acc = c.IsFocused ? c.ControlId + ":" + AllLabelText(c, 4) + "|" : "";
        auto f = cast<CGameManialinkFrame>(c);
        if (f !is null) for (uint i = 0; i < f.Controls.Length; i++) acc += CollectFocused(f.Controls[i], depth - 1);
        return acc;
    }

    string AllLabelText(CGameManialinkControl@ c, int depth) {
        if (c is null || depth < 0) return "";
        string v = ReadLabelValue(c);
        auto f = cast<CGameManialinkFrame>(c);
        if (f !is null) for (uint i = 0; i < f.Controls.Length; i++) {
            string s = AllLabelText(f.Controls[i], depth - 1);
            if (s.Length > 0) v += (v.Length > 0 ? " " : "") + s;
        }
        return v;
    }

    void DevNavTick() {
        if (Setting_DevNav.Length == 0) return;
        string seq = Setting_DevNav;
        string expect = Setting_DevNavExpect;
        Setting_DevNav = "";
        Setting_DevNavExpect = "";
        auto parts = seq.Split(",");
        for (uint i = 0; i < parts.Length; i++) {
            if (parts[i].Trim() == "Select") {
                string focus = FocusedDescr();
                if (expect.Length == 0 || !focus.ToLower().Contains(expect.ToLower())) {
                    warn("[FixSkinBrowserCharPilot] devnav REFUSED Select: expect='" + expect + "' focus='" + focus + "'");
                    return;
                }
                print("[FixSkinBrowserCharPilot] devnav Select allowed: focus='" + focus + "'");
            }
            SendNav(parts[i]);
            if (i + 1 < parts.Length) sleep(350);
        }
    }
}
