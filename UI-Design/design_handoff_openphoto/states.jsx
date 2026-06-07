/* states.jsx — first-launch, empty Bin */

function Bin() {
  return (
    <div className="content">
      <div className="toolbar">
        <div className="tb-title">Bin</div>
        <div className="tb-spacer"></div>
        <span className="tb-sub">Items are kept 30 days, then permanently deleted</span>
      </div>
      <div className="empty-state">
        <span className="empty-ico"><Icon n="bin" size={40} stroke={1.3} /></span>
        <div className="empty-title">Bin is empty</div>
        <div className="empty-sub">Deleted photos rest here for 30 days before they’re gone for good.<br />Nothing leaves your drives until you empty it.</div>
      </div>
    </div>
  );
}

function FirstLaunch({ onDone }) {
  const [folders, setFolders] = React.useState([
    { path: "~/Pictures/Photos", count: "41,208", status: "ready" },
    { path: "/Volumes/T7 Archive/Library", count: "58,212", status: "canonical" },
  ]);
  return (
    <div className="firstrun">
      <div className="fr-card">
        <div className="fr-mark"><span className="fr-aperture"><Icon n="lens" size={34} stroke={1.4} /></span></div>
        <div className="fr-title">Welcome to OpenPhoto</div>
        <div className="fr-sub">Your library is just folders you already own. Point OpenPhoto at them — nothing is copied, moved, or locked in. You stay sovereign over every file.</div>

        <div className="fr-folders">
          {folders.map((f, i) => (
            <div key={i} className="fr-folder">
              <span className="fr-fico"><Icon n="folderOpen" size={20} /></span>
              <div className="fr-fmeta">
                <div className="fr-fpath mono">{f.path}</div>
                <div className="faint" style={{ fontSize: 12 }}>{f.count} photos found</div>
              </div>
              {f.status === "canonical"
                ? <span className="dev-badge canon">canonical</span>
                : <span className="fstat ok lg"><Icon n="checkSmall" size={13} stroke={2.6} /></span>}
              <button className="iconbtn sm"><Icon n="close" size={13} /></button>
            </div>
          ))}
          <button className="fr-add"><Icon n="plus" size={16} /> Choose a folder…</button>
        </div>

        <div className="fr-note">
          <Icon n="seal" size={15} className="muted" />
          <span>OpenPhoto reads and writes standard files in place. Your originals never enter a hidden database.</span>
        </div>

        <div className="fr-actions">
          <button className="btn btn-ghost btn-lg">Learn how it works</button>
          <button className="btn btn-primary btn-lg" onClick={onDone}>Open library <Icon n="chevR" size={15} /></button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Bin, FirstLaunch });
