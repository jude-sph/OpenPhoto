/* import.jsx — slow & purposeful device import */

function Import() {
  const [sel, setSel] = React.useState(() => new Set(IMPORT_ITEMS.filter((i) => i.sel && !i.dupe).map((i) => i.id)));
  const [phase, setPhase] = React.useState("select"); // select | importing | imported
  const [prog, setProg] = React.useState(0);
  const [dest, setDest] = React.useState("2025/lisbon25");
  const [destOpen, setDestOpen] = React.useState(false);

  const total = IMPORT_ITEMS.length;
  const dupes = IMPORT_ITEMS.filter((i) => i.dupe).length;
  const count = sel.size;

  const toggle = (id, dupe) => {
    if (dupe) return;
    setSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  };

  const startImport = () => {
    setPhase("importing"); setProg(0);
    const t = setInterval(() => setProg((p) => {
      if (p >= 100) { clearInterval(t); setPhase("imported"); return 100; }
      return p + 4;
    }), 70);
  };

  const destName = dest.split("/").pop();
  const destOptions = ["2025/lisbon25", "2025/screenshots", "2024/canada23", "inbox"];

  return (
    <div className="content">
      <div className="toolbar">
        <div className="tb-title" style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <Icon n="iphone" size={16} className="muted" /> Jude’s iPhone
        </div>
        <div className="tb-sub" style={{ marginLeft: 6 }}>{total} new since last import · 1.9 GB</div>
        <div className="tb-spacer"></div>
        {phase === "select" && (
          <>
            <button className="chip" onClick={() => setSel(new Set(IMPORT_ITEMS.filter(i=>!i.dupe).map(i=>i.id)))}>Select all</button>
            <button className="chip" onClick={() => setSel(new Set())}>Deselect</button>
          </>
        )}
      </div>

      <div className="scroll">
        <div className="import-grid">
          {IMPORT_ITEMS.map((it) => {
            const on = sel.has(it.id);
            return (
              <div key={it.id} className={"icell" + (on ? " sel" : "") + (it.dupe ? " dupe" : "")}
                   onClick={() => toggle(it.id, it.dupe)}>
                <img src={img(it.seed, 360)} alt="" loading="lazy" draggable="false" />
                {it.type === "video" && <span className="badge-bl"><span className="mbadge dur"><Icon n="play" size={10} />{it.dur}</span></span>}
                {it.type === "live" && <span className="badge-tr"><span className="mbadge"><Icon n="live" size={11} stroke={1.8} />LIVE</span></span>}
                {it.dupe ? (
                  <span className="dupe-badge"><Icon n="checkSmall" size={12} stroke={2.4} /> Already in library</span>
                ) : (
                  <span className="ichk">{on ? <Icon n="checkSmall" size={15} stroke={2.4} /> : null}</span>
                )}
              </div>
            );
          })}
        </div>
        <div style={{ height: 110 }}></div>
      </div>

      {/* footer action bar */}
      <div className="import-bar">
        {phase === "select" && (
          <>
            <div className="ib-info">
              <span className="ib-count tnum">{count}</span> of {total} selected
              {dupes > 0 && <span className="ib-dupe">· {dupes} already in library, skipped</span>}
            </div>
            <div className="ib-dest">
              <span className="faint" style={{ fontSize: 12.5 }}>Import into</span>
              <div className="dest-pick" onClick={() => setDestOpen((o) => !o)}>
                <Icon n="folderOpen" size={15} className="muted" />
                <span>{destName}</span>
                <Icon n="chevD" size={12} className="faint" />
                {destOpen && (
                  <div className="dest-menu" onClick={(e) => e.stopPropagation()}>
                    {destOptions.map((o) => (
                      <div key={o} className={"dest-opt" + (o === dest ? " on" : "")}
                           onClick={() => { setDest(o); setDestOpen(false); }}>
                        <Icon n="folderOpen" size={14} /> {o}
                        {o === dest && <Icon n="checkSmall" size={13} stroke={2.4} style={{ marginLeft: "auto" }} />}
                      </div>
                    ))}
                    <div className="dest-opt new"><Icon n="plus" size={14} /> New folder…</div>
                  </div>
                )}
              </div>
            </div>
            <div className="tb-spacer"></div>
            <button className="btn btn-primary btn-lg" disabled={!count} onClick={startImport}>
              <Icon n="arrowDown" size={16} stroke={2} /> <span>Import {count} item{count !== 1 ? "s" : ""}</span>
            </button>
          </>
        )}

        {phase === "importing" && (
          <>
            <div className="ib-info" style={{ flex: 1 }}>
              <div style={{ fontWeight: 600, marginBottom: 7 }}>Copying &amp; verifying… {Math.round(prog)}%</div>
              <div className="activity-bar" style={{ maxWidth: 520 }}><div className="activity-fill" style={{ width: prog + "%" }}></div></div>
              <div className="faint tnum" style={{ fontSize: 12, marginTop: 6 }}>
                {Math.round((prog / 100) * count)} of {count} · checksum verified before any deletion
              </div>
            </div>
          </>
        )}

        {phase === "imported" && (
          <>
            <div className="ib-info">
              <div style={{ fontWeight: 600, display: "flex", alignItems: "center", gap: 8 }}>
                <span className="fstat ok lg"><Icon n="checkSmall" size={14} stroke={2.6} /></span>
                {count} items imported &amp; verified into {destName}
              </div>
              <div className="faint" style={{ fontSize: 12.5, marginTop: 4 }}>Originals still on iPhone. Free up space when you’re ready.</div>
            </div>
            <div className="tb-spacer"></div>
            <button className="btn btn-ghost btn-lg" onClick={() => setPhase("select")}>Done</button>
            <button className="btn btn-danger btn-lg">
              <Icon n="bin" size={15} /> <span>Delete {count} imported from iPhone</span>
            </button>
          </>
        )}
      </div>
    </div>
  );
}

Object.assign(window, { Import });
