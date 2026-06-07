/* sync.jsx — canonical-drive sync plan pre-flight review */

function SyncRow({ icon, n, label, sub, tone, children, expandable, open, onToggle }) {
  return (
    <div className={"sync-row" + (tone ? " " + tone : "")}>
      <div className="sync-row-main" onClick={expandable ? onToggle : undefined} style={{ cursor: expandable ? "pointer" : "default" }}>
        <span className="sync-ico"><Icon n={icon} size={18} /></span>
        <span className="sync-n tnum">{n}</span>
        <span className="sync-label">{label}<span className="faint" style={{ fontWeight: 400, marginLeft: 8 }}>{sub}</span></span>
        {expandable && <span className="sync-chev"><Icon n={open ? "chevD" : "chevR"} size={15} stroke={2.2} /></span>}
      </div>
      {open && children}
    </div>
  );
}

function Sync() {
  const [open, setOpen] = React.useState(true);
  const [done, setDone] = React.useState(false);
  const delItems = ALL_PHOTOS.slice(10, 24);

  return (
    <div className="content">
      <div className="toolbar">
        <div className="tb-title" style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <Icon n="externalDrive" size={16} className="muted" /> T7 Archive
          <span className="dev-badge canon" style={{ marginLeft: 2 }}>canonical</span>
        </div>
        <div className="tb-spacer"></div>
        <span className="tb-sub">Connected · last sync 6 days ago</span>
      </div>

      <div className="scroll">
        <div className="sync-wrap">
          {/* lead stat */}
          <div className="sync-hero">
            <div className="sync-hero-stat tnum">230</div>
            <div>
              <div className="sync-hero-title">items exist only on this Mac</div>
              <div className="faint" style={{ fontSize: 13, marginTop: 2 }}>Not yet on any backup. Syncing copies them to T7 Archive.</div>
            </div>
            <div className="tb-spacer"></div>
            <div className="sync-hero-bar">
              <div className="shb-seg mac" style={{ width: "62%" }}></div>
              <div className="shb-seg t7" style={{ width: "30%" }}></div>
              <div className="shb-seg none" style={{ width: "8%" }}></div>
            </div>
          </div>

          <div className="sync-card">
            <div className="sync-card-head">
              <span style={{ fontWeight: 650, fontSize: 14 }}>Sync plan</span>
              <span className="faint tnum" style={{ fontSize: 12.5 }}>MacBook → T7 Archive · 3.4 GB to transfer</span>
            </div>

            <SyncRow icon="arrowDown" n="412" label="new items" sub="3.2 GB · photos, videos, sidecars" tone="add" />
            <SyncRow icon="tag" n="18" label="metadata updates" sub="captions, ratings, people names" tone="meta" />
            <SyncRow icon="folderOpen" n="2" label="folder renames" sub="canada23 → 2023/canada23 · _new → inbox" tone="meta" />
            <SyncRow icon="bin" n="14" label="deletions need review" sub="will move to the drive’s Bin" tone="del"
                     expandable open={open} onToggle={() => setOpen((o) => !o)}>
              <div className="del-panel">
                <div className="del-thumbs">
                  {delItems.map((p) => (
                    <div key={p.id} className="del-thumb">
                      <img src={img(p.seed, 200)} alt="" draggable="false" />
                      <span className="del-x"><Icon n="close" size={11} stroke={2.4} /></span>
                    </div>
                  ))}
                </div>
                <div className="del-actions">
                  <span className="faint" style={{ fontSize: 12.5 }}>These were removed on this Mac. Approve to move them to the T7 Bin (recoverable for 30 days).</span>
                  <div className="tb-spacer"></div>
                  <button className="btn btn-ghost" style={{ height: 28 }}>Keep all</button>
                  <button className="btn btn-ghost" style={{ height: 28 }}>Review each</button>
                </div>
              </div>
            </SyncRow>
          </div>

          <div className="sync-foot">
            <span className="faint" style={{ fontSize: 12.5 }}>Nothing is deleted from the Mac. Sync is one-way to the canonical drive.</span>
            <div className="tb-spacer"></div>
            <button className="btn btn-ghost btn-lg">Schedule for later</button>
            <button className="btn btn-primary btn-lg" onClick={() => setDone(true)}>
              <Icon n="sync" size={16} stroke={2} /> Sync to T7 Archive
            </button>
          </div>

          {done && (
            <div className="banner ok-banner" style={{ margin: "16px 0 0" }}>
              <span className="banner-ico ok"><Icon n="checkSmall" size={16} stroke={2.4} /></span>
              <span className="banner-txt"><b>Sync complete.</b> 412 items copied · 230 Mac-only items are now backed up.</span>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Sync });
