namespace FSB {
    // The preview runs as ManiaScript in a UI layer this plugin owns, because the
    // menu scene manager (MenuSceneMgr) is reachable from ManiaScript in the menu
    // ManiaApp but not from AngelScript.
    //
    // Protocol (same as pilot-preview): the plugin writes inputs as data attributes
    // on Page.MainFrame (prefix "i-"), then "i-action" and a new "i-seq". The script
    // runs the action once per new sequence number and answers with "o-ack" plus
    // outputs (prefix "o-"). "i-beat" is a heartbeat; "i-retire" tears down.
    //
    // A ManiaScript compile error opens the game's native debugger over the whole
    // window, and there is no offline compiler. So every construct in this script is
    // copied from pilot-preview's in-game-proven SCRIPT_BODY (custom-pilot
    // plugin/pilot-preview, see PRECEDENTS.md) or from Nadeo's own scripts. The two
    // constructs pilot-preview does not use (ItemSetPivot, and reading i-pilotskin
    // directly) have Nadeo precedents noted in PRECEDENTS.md.
    //
    // A line-leading '#' in an AngelScript string is eaten by Openplanet's
    // preprocessor, so the Include directive is assembled at runtime.
    const string SCRIPT_BODY = """
Real AttrReal(CMlFrame _Root, Text _Key) {
	return TL::ToReal(_Root.DataAttributeGet(_Key));
}

Boolean AttrBool(CMlFrame _Root, Text _Key) {
	return _Root.DataAttributeGet(_Key) == "1";
}

Vec3 AttrVec(CMlFrame _Root, Text _Prefix) {
	return <AttrReal(_Root, _Prefix ^ "x"), AttrReal(_Root, _Prefix ^ "y"), AttrReal(_Root, _Prefix ^ "z")>;
}

main() {
	declare CMlFrame Root <=> Page.MainFrame;
	declare CMlCamera Cam <=> (Page.GetFirstChild("fsc-camera") as CMlCamera);
	declare Ident Scene = NullId;
	declare Ident Pilot = NullId;
	declare Text PilotKey = "";
	declare Text LastSeq = "";
	declare Text LastBeat = "";
	declare Integer BeatAt = Now;
	declare Integer BeatFrames = 0;
	declare Boolean Retired = False;
	PageAlwaysUpdateScript = True;
	Cam.Visible = False;
	Root.DataAttributeSet("o-manager", "" ^ (MenuSceneMgr != Null));
	Root.DataAttributeSet("o-status", "idle");
	Root.DataAttributeSet("o-ready", "1");
	while (True) {
		yield;
		Root.DataAttributeSet("o-now", "" ^ Now);
		declare Text Beat = Root.DataAttributeGet("i-beat");
		if (Beat != LastBeat) {
			LastBeat = Beat;
			BeatAt = Now;
			BeatFrames = 0;
		} else {
			BeatFrames += 1;
		}
		// Both a time and a frame count, so a long hitch (loading) alone cannot retire it.
		if (!Retired && (AttrBool(Root, "i-retire") || (Now - BeatAt > 10000 && BeatFrames > 150))) {
			if (Pilot != NullId) MenuSceneMgr.ItemDestroy(Scene, Pilot);
			if (Scene != NullId) MenuSceneMgr.SceneDestroy(Scene);
			Pilot = NullId;
			Scene = NullId;
			Cam.Visible = False;
			Retired = True;
			Root.DataAttributeSet("o-status", "retired");
			Root.DataAttributeSet("o-scene", "");
			Root.DataAttributeSet("o-pilot", "");
		}
		declare Text Seq = Root.DataAttributeGet("i-seq");
		if (Retired || Seq == "" || Seq == LastSeq) continue;
		LastSeq = Seq;
		declare Text Action = Root.DataAttributeGet("i-action");
		declare Text Err = "";
		declare Text Did = "";
		if (Action == "open") {
			// Nadeo order (BrowserAPI FocusSkin, Garage DisplayScene): the camera
			// control is made visible BEFORE SceneCreate. A scene appears to bind
			// to the camera visible at creation time, so always recreate it here.
			Cam.Visible = True;
			if (Scene != NullId && AttrBool(Root, "i-forcepilot")) {
				if (Pilot != NullId) MenuSceneMgr.ItemDestroy(Scene, Pilot);
				MenuSceneMgr.SceneDestroy(Scene);
				Pilot = NullId;
				Scene = NullId;
				PilotKey = "";
				Did = Did ^ "scene-,";
			}
			if (Scene == NullId) {
				Scene = MenuSceneMgr.SceneCreate("Empty");
				if (Scene != NullId) Did = Did ^ "scene+,";
			}
			if (Scene == NullId) {
				Err = "SceneCreate returned NullId";
			} else {
				declare Text PilotSkin = Root.DataAttributeGet("i-pilotskin");
				declare Text PilotUrl = Root.DataAttributeGet("i-piloturl");
				Root.DataAttributeSet("o-skin", PilotSkin);
				declare Text WantPilot = PilotSkin ^ "|" ^ PilotUrl ^ "|" ^ Root.DataAttributeGet("i-turntable");
				declare Boolean PilotChange = WantPilot != PilotKey || AttrBool(Root, "i-forcepilot");
				if (PilotChange && Pilot != NullId) {
					MenuSceneMgr.ItemDestroy(Scene, Pilot);
					Pilot = NullId;
					PilotKey = "";
					Did = Did ^ "pilot-,";
				}
				if (PilotChange && PilotSkin != "") {
					// Same 5-arg form as Garage.Script.txt:1502 (name, url, options).
					Pilot = MenuSceneMgr.ItemCreate(Scene, "CharacterPilot", PilotSkin, PilotUrl, "");
					if (Pilot == NullId) {
						Err = "pilot ItemCreate returned NullId";
					} else {
						PilotKey = WantPilot;
						Did = Did ^ "pilot+,";
						MenuSceneMgr.ItemSetPlayerState(Scene, Pilot, LocalUser);
						MenuSceneMgr.ItemSetLocation(Scene, Pilot, <0., 0., 0.>, AttrReal(Root, "i-pilotangle"), AttrBool(Root, "i-turntable"));
						MenuSceneMgr.ItemSetPivot(Scene, Pilot, <0., 0., 0.>);
						MenuSceneMgr.ItemTriggerPlayerGesture(Scene, Pilot);
					}
				}
				if (AttrBool(Root, "i-applycam")) MenuSceneMgr.CameraSetLocation(Scene, AttrVec(Root, "i-cam"), AttrReal(Root, "i-campitch"), AttrReal(Root, "i-camfov"));
				Root.DataAttributeSet("o-status", "open");
			}
		} else if (Action == "close") {
			if (Pilot != NullId) MenuSceneMgr.ItemDestroy(Scene, Pilot);
			if (Scene != NullId) MenuSceneMgr.SceneDestroy(Scene);
			Pilot = NullId;
			Scene = NullId;
			PilotKey = "";
			Cam.Visible = False;
			Did = "closed";
			Root.DataAttributeSet("o-status", "closed");
		} else if (Action == "camera") {
			MenuSceneMgr.CameraSetLocation(Scene, AttrVec(Root, "i-cam"), AttrReal(Root, "i-campitch"), AttrReal(Root, "i-camfov"));
			Did = "camera";
		} else {
			Err = "unknown action " ^ Action;
		}
		Root.DataAttributeSet("o-err", Err);
		Root.DataAttributeSet("o-did", Did);
		Root.DataAttributeSet("o-scene", "" ^ Scene);
		Root.DataAttributeSet("o-pilot", "" ^ Pilot);
		Root.DataAttributeSet("o-ack", Seq);
	}
}
""";

    // Where the preview sits, in manialink units: the page is 320 x 180 units with
    // (0,0) at the centre, x to the right, y UP. By default this is the rect of the
    // game's own skin-preview camera (BrowserAPI `camera-skin`, which our monitor
    // reads live), falling back to the static values from BrowserAPI.Script.txt:792-796.
    class Rect {
        float x = 51, y = -33, w = 80, h = 75; // centre and size (manialink units)
        // Fullscreen camera (Garage.Script.txt:772 form) offset by (x, y) like the
        // garage's frame-camera; w/h are then ignored.
        bool fullscreen = false;
        float z = Setting_DevCamZ;

        bool Same(const Rect@ o) {
            if (o is null) return false;
            return fullscreen == o.fullscreen && Math::Abs(z - o.z) < 0.01
                && Math::Abs(x - o.x) < 0.01 && Math::Abs(y - o.y) < 0.01
                && Math::Abs(w - o.w) < 0.01 && Math::Abs(h - o.h) < 0.01;
        }
    }

    // Static attributes only; the script never moves or resizes anything. A new
    // rectangle means a new layer (EnsureLayer).
    // Precedents: sub-rectangle camera with pos and no fullscreen = BrowserAPI.Script.txt:796
    // (pos="51 -33" size="80 75" hidden="1"); attribute numbers written with decimals.
    string PageXml(const Rect@ r) {
        string camXml;
        if (r.fullscreen) {
            // Garage.Script.txt:771-772: <frame id="frame-camera" pos=...><camera ... size="320 180" fullscreen="1"/>
            camXml = '<frame pos="' + Num(r.x) + ' ' + Num(r.y) + '" z-index="1">'
                + '<camera id="fsc-camera" halign="center" valign="center" size="320 180" fullscreen="1" z-index="0" hidden="1"/>'
                + '</frame>';
        } else {
            // z-index above the browser frame (Garage frame-browser z=7, its camera z=5):
            // with z 1 the browser panel quads drew over our camera.
            camXml = '<camera id="fsc-camera" pos="' + Num(r.x) + ' ' + Num(r.y) + '" size="' + Num(r.w) + ' ' + Num(r.h)
                + '" halign="center" valign="center" z-index="' + Num(r.z) + '" hidden="1"/>';
        }
        return '<manialink name="FixSkinBrowserCharPilot" version="3">'
            + camXml
            + '<script><!--\n' + "#" + 'Include "TextLib" as TL\n' + SCRIPT_BODY + '\n--></script></manialink>';
    }

    // Plain decimal with at most two places, no exponent (manialink attributes).
    string Num(float v) {
        return Text::Format("%.2f", v);
    }
}
