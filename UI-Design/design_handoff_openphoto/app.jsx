/* app.jsx — OpenPhoto shell: router, theme, viewer, tweaks */

const ACCENTS = {
  "coral-red": "#CF5C57",
  "terracotta": "#D9694C",
  "amber": "#E8845B",
  "brass": "#C99A3F",
};
function hexToRgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; }
function lighten(h, amt) {
  const [r, g, b] = hexToRgb(h);
  const f = (c) => Math.round(c + (255 - c) * amt);
  return `rgb(${f(r)}, ${f(g)}, ${f(b)})`;
}
function accentVars(hex) {
  const [r, g, b] = hexToRgb(hex);
  return {
    "--accent": hex,
    "--accent-hi": lighten(hex, 0.18),
    "--accent-dim": `rgba(${r}, ${g}, ${b}, 0.16)`,
    "--accent-ring": `rgba(${r}, ${g}, ${b}, 0.55)`,
  };
}

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "dark",
  "accent": "coral-red",
  "density": "regular",
  "devices": true,
  "drift": true
}/*EDITMODE-END*/;

const DENSITY_CELL = { compact: 104, regular: 132, comfy: 174 };

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [screen, setScreen] = React.useState("timeline");
  const [viewerPhoto, setViewerPhoto] = React.useState(null);
  const [cell, setCell] = React.useState(DENSITY_CELL[t.density] || 132);
  const [firstRun, setFirstRun] = React.useState(false);
  const [drift, setDrift] = React.useState(true);

  // react to density tweak
  React.useEffect(() => { setCell(DENSITY_CELL[t.density] || 132); }, [t.density]);
  React.useEffect(() => { setDrift(t.drift); }, [t.drift]);

  const themeClass = t.theme === "light" ? "theme-light" : "theme-dark";
  const rootStyle = { ...accentVars(ACCENTS[t.accent] || ACCENTS["coral-red"]) };

  const go = (s) => { setViewerPhoto(null); setScreen(s); };

  let body;
  if (screen === "timeline") body = <Timeline onOpen={setViewerPhoto} cell={cell} setCell={setCell} />;
  else if (screen === "folders") body = <Folders onOpen={setViewerPhoto} cell={cell} setCell={setCell} drift={drift} dismissDrift={() => setDrift(false)} />;
  else if (screen === "import") body = <Import />;
  else if (screen === "sync") body = <Sync />;
  else if (screen === "people") body = <People />;
  else if (screen === "map") body = <MapScreen onOpen={setViewerPhoto} />;
  else if (screen === "bin") body = <Bin />;
  else body = <Timeline onOpen={setViewerPhoto} cell={cell} setCell={setCell} />;

  return (
    <div className={themeClass} style={{ ...rootStyle, width: "100%", height: "100%" }}>
      <div className="desktop">
        <div className="win">
          <Sidebar screen={screen} go={go} devicesConnected={t.devices} />
          {body}
          {viewerPhoto && <Viewer p={viewerPhoto} onClose={() => setViewerPhoto(null)} />}
          {firstRun && <FirstLaunch onDone={() => setFirstRun(false)} />}
        </div>
      </div>

      <TweaksPanel>
        <TweakSection label="Appearance" />
        <TweakRadio label="Mode" value={t.theme} options={["dark", "light"]} onChange={(v) => setTweak("theme", v)} />
        <TweakColor label="Accent" value={ACCENTS[t.accent]}
                    options={Object.values(ACCENTS)}
                    onChange={(v) => { const k = Object.keys(ACCENTS).find((x) => ACCENTS[x] === v); setTweak("accent", k || "coral-red"); }} />
        <TweakRadio label="Grid density" value={t.density} options={["compact", "regular", "comfy"]} onChange={(v) => setTweak("density", v)} />

        <TweakSection label="Demo states" />
        <TweakToggle label="Devices connected" value={t.devices} onChange={(v) => setTweak("devices", v)} />
        <TweakToggle label="Drift warning banner" value={t.drift} onChange={(v) => setTweak("drift", v)} />
        <TweakButton label="Show first-launch welcome" onClick={() => setFirstRun(true)} secondary />

        <TweakSection label="Jump to screen" />
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 6 }}>
          {[["timeline","Timeline"],["folders","Folders"],["import","Import"],["sync","Sync plan"],["people","People"],["map","Map"],["bin","Bin (empty)"]].map(([k,l]) => (
            <button key={k} className="tw-jump" onClick={() => go(k)}
              style={{ padding: "7px 8px", fontSize: 12, borderRadius: 7, cursor: "pointer",
                       border: "1px solid " + (screen===k?"var(--accent)":"rgba(128,128,128,.3)"),
                       background: screen===k?"var(--accent)":"transparent",
                       color: screen===k?"#fff":"inherit", fontFamily: "inherit" }}>{l}</button>
          ))}
        </div>
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
