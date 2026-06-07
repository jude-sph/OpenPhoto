/* folders.jsx — folder tree (status badges) + grid of selected folder */

function FolderStatus({ s }) {
  if (s === "synced") return <span className="fstat ok" title="Synced to T7 Archive"><Icon n="checkSmall" size={12} stroke={2.4} /></span>;
  if (s === "local") return <span className="fstat warn" title="Local only — not backed up"><Icon n="warn" size={12} stroke={2} /></span>;
  return <span className="fstat off" title="Offline — evicted from this Mac"><Icon n="driveSlash" size={12} stroke={2} /></span>;
}

function FolderTree({ selected, onSelect }) {
  const [open, setOpen] = React.useState({ "2025": true, "2024": true, "2022": true });
  return (
    <div className="ftree">
      <div className="ftree-head">
        <span>Folders</span>
        <button className="iconbtn sm" title="New folder"><Icon n="plus" size={14} /></button>
      </div>
      <div className="ftree-scroll">
        {FOLDERS.map((f) => {
          const isParent = f.kids || f.depth === 0;
          const hidden = f.depth === 1 && open[f.path.split("/")[0]] === false;
          if (hidden) return null;
          return (
            <div key={f.path}
                 className={"frow" + (selected === f.path ? " active" : "")}
                 style={{ paddingLeft: 12 + f.depth * 16 }}
                 onClick={() => onSelect(f.path)}>
              {f.depth === 0 ? (
                <span className="fchev" onClick={(e) => { e.stopPropagation(); setOpen((o) => ({ ...o, [f.path]: !o[f.path] })); }}>
                  <Icon n={open[f.path] === false ? "chevR" : "chevD"} size={12} stroke={2.2} />
                </span>
              ) : <span className="fchev"></span>}
              <span className="fico"><Icon n={f.depth === 0 ? "folders" : "folderOpen"} size={16} /></span>
              <span className="fname">{f.name}</span>
              <FolderStatus s={f.status} />
              {f.count != null && <span className="fcount tnum">{f.count.toLocaleString()}</span>}
            </div>
          );
        })}
      </div>
      <div className="ftree-legend">
        <span><span className="fstat ok"><Icon n="checkSmall" size={11} stroke={2.4} /></span>Synced</span>
        <span><span className="fstat warn"><Icon n="warn" size={11} stroke={2} /></span>Local-only</span>
        <span><span className="fstat off"><Icon n="driveSlash" size={11} stroke={2} /></span>Offline</span>
      </div>
    </div>
  );
}

function Folders({ onOpen, cell, setCell, drift, dismissDrift }) {
  const [sel, setSel] = React.useState("2025/lisbon25");
  const folder = FOLDERS.find((f) => f.path === sel) || FOLDERS[1];
  const breadcrumb = sel.split("/");
  return (
    <div className="content">
      <div className="toolbar">
        <div className="tb-title" style={{ display: "flex", alignItems: "center", gap: 6 }}>
          {breadcrumb.map((b, i) => (
            <span key={i} style={{ display: "flex", alignItems: "center", gap: 6 }}>
              {i > 0 && <Icon n="chevR" size={12} className="faint" />}
              <span style={{ color: i === breadcrumb.length - 1 ? "var(--text)" : "var(--text-dim)", fontWeight: i === breadcrumb.length - 1 ? 600 : 500 }}>{b}</span>
            </span>
          ))}
        </div>
        <div className="tb-sub" style={{ marginLeft: 8 }}>{(folder.count || 642).toLocaleString()} items · 3.4 GB</div>
        <div className="tb-spacer"></div>
        <button className="chip"><span className="chip-ico"><Icon n="seal" size={14} /></span>Reveal in Finder</button>
        <GridSizeSlider cell={cell} setCell={setCell} />
      </div>

      <div className="fbody">
        <FolderTree selected={sel} onSelect={setSel} />
        <div className="content" style={{ background: "transparent" }}>
          {drift && (
            <div className="banner warn-banner">
              <span className="banner-ico"><Icon n="warn" size={16} stroke={2} /></span>
              <span className="banner-txt"><b>3 files on T7 Archive changed outside OpenPhoto.</b> Review before they sync back.</span>
              <button className="btn btn-ghost" style={{ height: 26 }}>Review</button>
              <button className="iconbtn sm" onClick={dismissDrift}><Icon n="close" size={13} /></button>
            </div>
          )}
          <div className="scroll">
            <div className="grid" style={{ "--cell": cell + "px", paddingTop: 16 }}>
              {FOLDER_GRID.map((p) => (
                <PhotoCell key={p.id} p={p} onClick={() => onOpen(p)} />
              ))}
            </div>
            <div style={{ height: 24 }}></div>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Folders, FolderTree, FolderStatus });
