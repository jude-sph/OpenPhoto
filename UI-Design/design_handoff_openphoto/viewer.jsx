/* viewer.jsx — full-bleed photo + toggleable inspector + offline prompt */

function PresenceRow({ presence }) {
  const nodes = [
    { k: "mac", label: "MacBook", state: presence.mac },
    { k: "t7", label: "T7 Archive", state: presence.t7 },
    { k: "backup", label: "Backup-B", state: presence.backup },
  ];
  return (
    <div className="presence">
      {nodes.map((n) => (
        <div key={n.k} className={"pres-node " + (n.state ? "on" : "off")}>
          <Icon n={n.k === "mac" ? "drive" : "externalDrive"} size={15} />
          <span className="pres-label">{n.label}</span>
          {n.state
            ? <span className="pres-ok"><Icon n="checkSmall" size={12} stroke={2.6} /></span>
            : <span className="pres-no">—</span>}
        </div>
      ))}
    </div>
  );
}

function Field({ label, children }) {
  return (
    <div className="insp-field">
      <div className="insp-flabel">{label}</div>
      <div className="insp-fval">{children}</div>
    </div>
  );
}

function Inspector({ p, onClose }) {
  const [cap, setCap] = React.useState(p.caption || "");
  const [rating, setRating] = React.useState(p.rating || (p.fav ? 4 : 0));
  const [tags, setTags] = React.useState(p.tags.length ? p.tags : ["lisbon", "summer"]);
  const ppl = p.people.map((id) => PEOPLE.find((x) => x.id === id)).filter(Boolean);

  return (
    <div className="inspector">
      <div className="insp-head">
        <span style={{ fontWeight: 650, fontSize: 14 }}>Info</span>
        <button className="iconbtn sm" onClick={onClose}><Icon n="close" size={14} /></button>
      </div>
      <div className="insp-scroll">
        {/* date/time */}
        <div className="insp-sec">
          <div className="insp-date">June 3, 2025 · 18:42</div>
          <div className="faint" style={{ fontSize: 12.5 }}>Tuesday afternoon · {p.place}</div>
        </div>

        {/* editable caption */}
        <Field label="Caption">
          <input className="insp-input" placeholder="Add a caption…" value={cap} onChange={(e) => setCap(e.target.value)} />
        </Field>

        {/* rating */}
        <Field label="Rating">
          <div className="stars">
            {[1, 2, 3, 4, 5].map((s) => (
              <span key={s} className={"star" + (s <= rating ? " on" : "")} onClick={() => setRating(s === rating ? 0 : s)}>
                <Icon n={s <= rating ? "starFill" : "star"} size={17} />
              </span>
            ))}
          </div>
        </Field>

        {/* people */}
        <Field label="People">
          <div className="insp-people">
            {ppl.map((pp) => (
              <div key={pp.id} className="ip-chip">
                <img src={img(pp.seed, 60)} alt="" /><span>{pp.name}</span>
              </div>
            ))}
            <button className="ip-add"><Icon n="plus" size={13} /> Add</button>
          </div>
        </Field>

        {/* tags */}
        <Field label="Tags">
          <div className="insp-tags">
            {tags.map((t) => (
              <span key={t} className="tagchip">{t}<span className="tagx" onClick={() => setTags(tags.filter((x) => x !== t))}><Icon n="close" size={9} stroke={2.6} /></span></span>
            ))}
            <button className="ip-add"><Icon n="plus" size={13} /></button>
          </div>
        </Field>

        <div className="insp-divider"></div>

        {/* camera / exif */}
        <div className="insp-sec">
          <div className="insp-cam"><Icon n="camera" size={16} className="muted" /><div><div style={{ fontWeight: 600, fontSize: 13 }}>{p.camera}</div><div className="faint" style={{ fontSize: 12 }}>{p.lens}</div></div></div>
          <div className="exif-grid">
            <div><span className="exk">ISO</span><span className="exv tnum">{p.exif.iso}</span></div>
            <div><span className="exk">Aperture</span><span className="exv tnum">ƒ{p.exif.f}</span></div>
            <div><span className="exk">Shutter</span><span className="exv tnum">{p.exif.sh}</span></div>
            <div><span className="exk">Focal</span><span className="exv tnum">{p.exif.mm} mm</span></div>
            <div><span className="exk">Size</span><span className="exv tnum">4032 × 3024</span></div>
            <div><span className="exk">File</span><span className="exv">12.4 MB · HEIC</span></div>
          </div>
        </div>

        {/* map */}
        <Field label="Location">
          <div className="insp-map">
            <div className="mini-map">
              <div className="mm-grid"></div>
              <div className="mm-pin" style={{ left: "50%", top: "46%" }}><Icon n="pin" size={22} /></div>
            </div>
            <div className="faint" style={{ fontSize: 12.5, marginTop: 6, display: "flex", alignItems: "center", gap: 5 }}>
              <Icon n="mappin" size={13} /> {p.place} · {p.lat.toFixed(3)}, {p.lng.toFixed(3)}
            </div>
          </div>
        </Field>

        <div className="insp-divider"></div>

        {/* presence */}
        <Field label="Presence — where this file physically lives">
          <PresenceRow presence={p.presence} />
        </Field>
        <div className="insp-path mono">~/Photos/{p.folder}/IMG_{p.id.replace("i", "40")}.HEIC</div>
      </div>
    </div>
  );
}

function Viewer({ p, onClose }) {
  const [inspector, setInspector] = React.useState(true);
  const [showFull, setShowFull] = React.useState(!p.offline);
  const idx = ALL_PHOTOS.findIndex((x) => x.id === p.id);
  const [cur, setCur] = React.useState(idx < 0 ? 0 : idx);
  const photo = ALL_PHOTOS[cur];

  React.useEffect(() => { setShowFull(!photo.offline); }, [cur]);
  React.useEffect(() => {
    const onKey = (e) => {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowRight") setCur((c) => Math.min(ALL_PHOTOS.length - 1, c + 1));
      if (e.key === "ArrowLeft") setCur((c) => Math.max(0, c - 1));
      if (e.key === "i") setInspector((v) => !v);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="viewer">
      <div className="v-top">
        <button className="iconbtn ghost" onClick={onClose}><Icon n="back" size={16} /></button>
        <div className="v-title">{photo.place} <span className="faint">· June 3, 2025</span></div>
        <div className="tb-spacer"></div>
        <button className="iconbtn ghost"><Icon n={photo.fav ? "heartFill" : "heart"} size={16} /></button>
        <button className="iconbtn ghost"><Icon n="share" size={16} /></button>
        <button className="iconbtn ghost"><Icon n="crop" size={16} /></button>
        <div style={{ width: 1, height: 20, background: "var(--hair-strong)", margin: "0 4px" }}></div>
        <button className={"iconbtn ghost" + (inspector ? " on" : "")} onClick={() => setInspector((v) => !v)}><Icon n="inspector" size={16} /></button>
      </div>

      <div className="v-body">
        <div className="v-stage">
          <button className="v-nav left" onClick={() => setCur((c) => Math.max(0, c - 1))}><Icon n="chevL" size={22} /></button>
          {showFull ? (
            <img className="v-img" src={imgW(photo.seed)} alt="" draggable="false" />
          ) : (
            <div className="offline-prompt">
              <img className="v-img blurred" src={img(photo.seed, 240)} alt="" draggable="false" />
              <div className="op-card">
                <span className="op-ico"><Icon n="externalDrive" size={30} /></span>
                <div className="op-title">Full resolution is on T7 Archive</div>
                <div className="op-sub">A preview is shown. Plug in the drive to view, edit, or export the original.</div>
                <div className="op-actions">
                  <button className="btn btn-ghost" onClick={() => setShowFull(true)}>Show preview</button>
                  <button className="btn btn-primary"><Icon n="externalDrive" size={15} /> Locate drive</button>
                </div>
              </div>
            </div>
          )}
          {photo.type === "video" && showFull && (
            <button className="v-play"><Icon n="play" size={26} /></button>
          )}
          <button className="v-nav right" onClick={() => setCur((c) => Math.min(ALL_PHOTOS.length - 1, c + 1))}><Icon n="chevR" size={22} /></button>
        </div>
        {inspector && <Inspector p={photo} onClose={() => setInspector(false)} />}
      </div>

      <div className="v-filmstrip">
        {ALL_PHOTOS.slice(Math.max(0, cur - 8), cur + 16).map((x) => {
          const i = ALL_PHOTOS.findIndex((y) => y.id === x.id);
          return (
            <div key={x.id} className={"fs-thumb" + (i === cur ? " on" : "")} onClick={() => setCur(i)}>
              <img src={img(x.seed, 120)} alt="" draggable="false" />
            </div>
          );
        })}
      </div>
    </div>
  );
}

Object.assign(window, { Viewer, Inspector, PresenceRow });
