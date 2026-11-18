// Layer lifecycle for the preview overlay. Ported from pilot-preview
// (spike.custom-pilot/plugin/pilot-preview/src/Preview.as), reduced to the menu
// context only. That file's lifecycle was proven in game on 2026-11-17; keep the
// same structure (no nod handles across frames, ack/retire protocol, sweeps).
namespace FSB {
    const string ATTACH_PREFIX = "FixSkinBrowserCharPilot_";
    const uint ACK_TIMEOUT_MS = 5000;

    string g_attachId = "";
    Rect@ g_rect = null;       // geometry baked into the live layer's XML
    int g_layerType = -1;      // EUILayerType the live layer was created with
    uint g_seq = 0;
    bool g_stopping = false;
    string g_pilotSkin = "";   // skin name the live layer currently shows

    CGameManiaApp@ OwnerMenu() {
        auto app = cast<CTrackMania>(GetApp());
        if (app is null || app.MenuManager is null) return null;
        return app.MenuManager.MenuCustom_CurrentManiaApp;
    }

    CGameUILayer@ FindLayer(CGameManiaApp@ owner, const string &in attachId) {
        if (owner is null || attachId.Length == 0) return null;
        for (uint i = 0; i < owner.UILayers.Length; i++) {
            auto layer = owner.UILayers[i];
            if (layer !is null && layer.AttachId == attachId) return layer;
        }
        return null;
    }

    CGameManialinkFrame@ RootOf(CGameUILayer@ layer) {
        if (layer is null || layer.LocalPage is null) return null;
        return layer.LocalPage.MainFrame;
    }

    string Out(CGameManialinkFrame@ root, const string &in key) {
        if (root is null || !root.DataAttributeExists("o-" + key)) return "";
        return root.DataAttributeGet("o-" + key);
    }

    void In(CGameManialinkFrame@ root, const string &in key, const string &in value) {
        root.DataAttributeSet("i-" + key, value);
    }
    void InF(CGameManialinkFrame@ root, const string &in key, float value) {
        In(root, key, Text::Format("%.5f", value));
    }
    void InB(CGameManialinkFrame@ root, const string &in key, bool value) {
        In(root, key, value ? "1" : "0");
    }

    // A layer holds no scene when its script is not running (never compiled) or it
    // says so itself; such a layer can be destroyed at once. Any other layer is asked
    // to retire (it destroys its own scene on the next frame) and destroyed later.
    bool HoldsNoScene(CGameUILayer@ layer) {
        if (layer is null || !layer.IsLocalPageScriptRunning) return true;
        string status = Out(RootOf(layer), "status");
        return status == "retired" || status == "closed" || status == "idle";
    }

    // Retire or destroy every layer of ours in this owner except the live one.
    // Never yields, so it is also safe from OnDestroyed.
    int SweepStale(CGameManiaApp@ owner) {
        int seen = 0;
        if (owner is null) return 0;
        for (int i = int(owner.UILayers.Length) - 1; i >= 0; i--) {
            auto layer = owner.UILayers[i];
            if (layer is null || !layer.AttachId.StartsWith(ATTACH_PREFIX) || layer.AttachId == g_attachId) continue;
            seen++;
            if (HoldsNoScene(layer)) {
                owner.UILayerDestroy(layer);
            } else {
                auto root = RootOf(layer);
                if (root !is null) InB(root, "retire", true);
                layer.IsVisible = false;
            }
        }
        return seen;
    }

    // Creates the layer if needed (or recreates it when the rectangle changed) and
    // waits until its script reports ready. On any failure here the new layer is
    // removed again, so a failed start leaves nothing behind.
    CGameManialinkFrame@ EnsureLayer(Rect@ rect, int layerType) {
        auto owner = OwnerMenu();
        if (owner is null) throw("no menu ManiaApp");
        if (g_attachId.Length > 0 && (g_rect is null || !g_rect.Same(rect) || g_layerType != layerType)) {
            CloseLive(true);
        }
        SweepStale(owner);
        auto layer = FindLayer(owner, g_attachId);
        if (layer is null) {
            g_attachId = ATTACH_PREFIX + Time::Now;
            @g_rect = rect;
            g_layerType = layerType;
            g_seq = 0;
            @layer = owner.UILayerCreate();
            if (layer is null) {
                g_attachId = ""; @g_rect = null; g_layerType = -1;
                throw("UILayerCreate returned null");
            }
            layer.AttachId = g_attachId;
            // Set the type before the page, as tm-dips-plus-plus does.
            layer.Type = CGameUILayer::EUILayerType(layerType);
            layer.ManialinkPage = PageXml(rect);
            layer.IsVisible = true;
        }
        uint64 deadline = Time::Now + ACK_TIMEOUT_MS;
        while (true) {
            @layer = FindLayer(OwnerMenu(), g_attachId);
            auto root = RootOf(layer);
            if (root !is null && Out(root, "ready") == "1") {
                if (Out(root, "manager") != "True") {
                    CloseLive(true);
                    throw("MenuSceneMgr is null in the menu ManiaApp; preview layer removed");
                }
                if (Out(root, "status") == "retired") {
                    CloseLive(true);
                    throw("preview layer had retired (heartbeat lost); removed");
                }
                return root;
            }
            if (layer is null) {
                g_attachId = ""; @g_rect = null;
                throw("preview layer disappeared while starting (left the menu?)");
            }
            if (Time::Now > deadline) {
                // A script that never reported ready holds no scene: remove its layer now.
                // Do NOT touch the native script debugger: hiding it from code on
                // 2026-11-17 was followed by a "Recovery restart..." of the playground.
                auto owner2 = OwnerMenu();
                bool running = layer.IsLocalPageScriptRunning;
                if (!running && owner2 !is null) owner2.UILayerDestroy(layer);
                else if (running) { auto r2 = RootOf(layer); if (r2 !is null) InB(r2, "retire", true); layer.IsVisible = false; }
                g_attachId = ""; @g_rect = null;
                throw("preview layer script did not report ready within " + ACK_TIMEOUT_MS + " ms (scriptRunning="
                    + (running ? "true" : "false") + "). If the native script debugger opened, a ManiaScript compile error is shown in it:"
                    + " capture the window, read the error, and stop using the game. Never hide the debugger from code.");
            }
            yield();
        }
        return null;
    }

    // Publish an action and wait for the script's acknowledgement.
    CGameManialinkFrame@ Run(CGameManialinkFrame@ root, const string &in action) {
        In(root, "action", action);
        string seq = tostring(++g_seq);
        In(root, "seq", seq);
        uint64 deadline = Time::Now + ACK_TIMEOUT_MS;
        while (true) {
            yield();
            auto layer = FindLayer(OwnerMenu(), g_attachId);
            @root = RootOf(layer);
            if (root is null) throw("preview layer disappeared while waiting for '" + action + "' (left the menu?)");
            if (Out(root, "ack") == seq) break;
            if (Time::Now > deadline) throw("no acknowledgement for '" + action + "' within " + ACK_TIMEOUT_MS + " ms");
        }
        string err = Out(root, "err");
        if (err.Length > 0) throw(err);
        return root;
    }

    string LiveSkin() { // lsp: ignore unused
        return g_pilotSkin;
    }

    void ForgetLive() {
        g_attachId = "";
        @g_rect = null;
        g_layerType = -1;
        g_pilotSkin = "";
    }

    // Close the live preview. wait=true (monitor loop, may yield): the script destroys
    // its items and scene and acknowledges, then the layer is destroyed. wait=false
    // (plugin unload, cannot yield): a layer that holds no scene is destroyed now;
    // otherwise it is told to retire and hidden, and its script removes the scene on
    // its next frame; the empty hidden layer is destroyed by the next sweep (next
    // plugin load or open).
    bool CloseLive(bool wait) {
        if (g_attachId.Length == 0) return false;
        auto owner = OwnerMenu();
        auto layer = FindLayer(owner, g_attachId);
        bool acked = false;
        if (layer !is null) {
            if (HoldsNoScene(layer)) {
                owner.UILayerDestroy(layer);
                acked = true;
            } else if (wait) {
                try { Run(RootOf(layer), "close"); acked = true; } catch { warn("[FixSkinBrowserCharPilot] close: " + getExceptionInfo()); }
                @owner = OwnerMenu();
                @layer = FindLayer(owner, g_attachId);
                if (layer !is null) {
                    if (acked || HoldsNoScene(layer)) {
                        owner.UILayerDestroy(layer);
                    } else {
                        auto root = RootOf(layer);
                        if (root !is null) InB(root, "retire", true);
                        layer.IsVisible = false;
                    }
                }
            } else {
                auto root = RootOf(layer);
                if (root !is null) InB(root, "retire", true);
                layer.IsVisible = false;
            }
        }
        ForgetLive();
        return acked;
    }
}
