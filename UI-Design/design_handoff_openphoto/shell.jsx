/* shell.jsx — Sidebar + shared photo cell/badges */

function TrafficLights() {
  return (
    <div className="traffic">
      <span className="light-dot r"></span>
      <span className="light-dot y"></span>
      <span className="light-dot g"></span>
    </div>
  );
}

function SBItem({ icon, label, count, active, badge, onClick, devIcon }) {
  return (
    <div className={"sb-item" + (active ? " active" : "") + (devIcon ? " dev-row" : "")} onClick={onClick}>
      <span className="sb-ico"><Icon n={icon} size={17} /></span>
      <span className="sb-txt">{label}</span>
      {badge ? <span className={"dev-badge " + badge.cls}>{badge.text}</span> : null}
      {count != null ? <span className="sb-count tnum">{count}</span> : null}
    </div>
  );
}

function Sidebar({ screen, go, devicesConnected }) {
  const lib = [
    { k: "timeline", icon: "timeline", label: "Timeline", count: "58,212" },
    { k: "folders", icon: "folders", label: "Folders" },
    { k: "people", icon: "people", label: "People", count: "214" },
    { k: "map", icon: "map", label: "Map" },
    { k: "bin", icon: "bin", label: "Bin", count: "38" },
  ];
  return (
    <div className="sidebar">
      <TrafficLights />
      <div className="sb-scroll">
        <div className="sb-group">
          <div className="sb-label">Library</div>
          {lib.map((it) => (
            <SBItem key={it.k} icon={it.icon} label={it.label} count={it.count}
                    active={screen === it.k} onClick={() => go(it.k)} />
          ))}
        </div>

        {devicesConnected && (
          <div className="sb-group">
            <div className="sb-label">Devices</div>
            <SBItem icon="iphone" label="Jude’s iPhone" devIcon active={screen === "import"} onClick={() => go("import")} />
            <SBItem icon="sd" label="Canon SD" devIcon onClick={() => go("import")} />
            <SBItem icon="externalDrive" label="T7 Archive" devIcon badge={{ cls: "canon", text: "canonical" }}
                    active={screen === "sync"} onClick={() => go("sync")} />
          </div>
        )}

        <div className="sb-group">
          <div className="sb-label">Albums</div>
          <SBItem icon="heart" label="Favorites" count="1,204" onClick={() => go("timeline")} />
          <SBItem icon="folderOpen" label="Recently Added" onClick={() => go("timeline")} />
        </div>
      </div>

      <Activity />
    </div>
  );
}

function Activity() {
  const [n, setN] = React.useState(2140);
  React.useEffect(() => {
    const t = setInterval(() => setN((v) => (v >= 58000 ? 2140 : v + 137)), 900);
    return () => clearInterval(t);
  }, []);
  const pct = Math.min(100, (n / 58000) * 100);
  return (
    <div className="activity">
      <div className="activity-top">
        <span className="spin"><Icon n="sync" size={13} stroke={2} /></span>
        <span>Indexing library</span>
      </div>
      <div className="activity-bar"><div className="activity-fill" style={{ width: pct + "%" }}></div></div>
      <div className="activity-sub">{n.toLocaleString()} of 58,000 · faces &amp; metadata</div>
    </div>
  );
}

/* ---- shared photo cell ---- */
function MediaBadges({ p }) {
  return (
    <>
      {p.offline && !p.type.match(/video|live/) && (
        <span className="offline-glyph" title="Full-res on T7 Archive"><Icon n="driveSlash" size={12} stroke={2} /></span>
      )}
      <div className="badge-tr">
        {p.type === "live" && <span className="mbadge"><Icon n="live" size={11} stroke={1.8} />LIVE</span>}
        {p.type === "video" && <span className="mbadge dur"><Icon n="play" size={10} />{p.dur}</span>}
      </div>
      {p.fav && <span className="fav-dot"><Icon n="heartFill" size={15} /></span>}
    </>
  );
}

function PhotoCell({ p, selected, onClick, showCheck, selectable }) {
  return (
    <div className={"cell" + (selected ? " sel" : "") + (p.offline ? " offline" : "")} onClick={onClick}>
      <img src={img(p.seed)} alt="" loading="lazy" draggable="false" />
      <MediaBadges p={p} />
      {(selectable) && (
        <span className="check">{selected ? <Icon n="checkSmall" size={13} stroke={2.4} /> : null}</span>
      )}
    </div>
  );
}

Object.assign(window, { Sidebar, SBItem, TrafficLights, Activity, PhotoCell, MediaBadges });
