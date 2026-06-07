/* people.jsx — face clusters, named + unnamed, merge/split, threshold popover */

function FaceTile({ person, selected, onSelect, big }) {
  return (
    <div className={"face" + (selected ? " sel" : "") + (person.name ? "" : " unnamed")} onClick={onSelect}>
      <div className="face-crop" style={big ? { width: 108, height: 108 } : null}>
        <img src={img(person.seed, 200)} alt="" draggable="false" />
        {selected && <span className="face-check"><Icon n="checkSmall" size={14} stroke={2.6} /></span>}
      </div>
      {person.name ? (
        <div className="face-name">{person.name}</div>
      ) : (
        <div className="face-name unnamed-name">Unnamed</div>
      )}
      <div className="face-count tnum">
        {person.count.toLocaleString()}
        {person.conf != null && <span className="face-conf">· {Math.round(person.conf * 100)}%</span>}
      </div>
    </div>
  );
}

function ThresholdPopover({ open, val, setVal, onClose }) {
  if (!open) return null;
  return (
    <div className="popover" onClick={(e) => e.stopPropagation()}>
      <div className="pop-title">Clustering threshold</div>
      <div className="pop-sub faint">Higher = stricter matches, more clusters. Lower = looser grouping.</div>
      <div className="pop-slider">
        <span className="faint" style={{ fontSize: 11 }}>Loose</span>
        <input type="range" min="40" max="95" value={val} onChange={(e) => setVal(+e.target.value)} />
        <span className="faint" style={{ fontSize: 11 }}>Strict</span>
      </div>
      <div className="pop-val tnum">{val}% confidence · re-clusters 214 people</div>
      <button className="btn btn-ghost" style={{ width: "100%", height: 28, marginTop: 8 }} onClick={onClose}>Apply</button>
    </div>
  );
}

function People() {
  const [sel, setSel] = React.useState(new Set());
  const [popover, setPopover] = React.useState(false);
  const [thresh, setThresh] = React.useState(72);
  const named = PEOPLE.filter((p) => p.name);
  const unnamed = PEOPLE.filter((p) => !p.name);

  const toggle = (id) => setSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });

  return (
    <div className="content" onClick={() => setPopover(false)}>
      <div className="toolbar">
        <div className="tb-title">People</div>
        <div className="tb-sub" style={{ marginLeft: 6 }}>6 named · 8 clusters to review</div>
        <div className="tb-spacer"></div>
        {sel.size > 0 ? (
          <div className="sel-actions">
            <span className="faint" style={{ fontSize: 12.5 }}>{sel.size} selected</span>
            <button className="chip" disabled={sel.size < 2}><Icon n="merge" size={14} /> Merge</button>
            <button className="chip"><Icon n="person" size={14} /> Name</button>
            <button className="chip"><Icon n="close" size={13} /> Not a person</button>
            <button className="chip" onClick={() => setSel(new Set())}>Clear</button>
          </div>
        ) : (
          <div style={{ position: "relative" }}>
            <button className="chip" onClick={(e) => { e.stopPropagation(); setPopover((o) => !o); }}>
              <span className="chip-ico"><Icon n="sliders" size={14} /></span>Clustering
            </button>
            <ThresholdPopover open={popover} val={thresh} setVal={setThresh} onClose={() => setPopover(false)} />
          </div>
        )}
      </div>

      <div className="scroll">
        <div className="ppl-wrap">
          <div className="ppl-section-label">Named</div>
          <div className="face-grid big">
            {named.map((p) => <FaceTile key={p.id} person={p} big selected={sel.has(p.id)} onSelect={() => toggle(p.id)} />)}
          </div>

          <div className="ppl-section-label" style={{ marginTop: 26 }}>
            Clusters to review
            <span className="faint" style={{ fontWeight: 400, marginLeft: 8, textTransform: "none", letterSpacing: 0 }}>
              Tap to name, select multiple to merge
            </span>
          </div>
          <div className="face-grid">
            {unnamed.map((p) => <FaceTile key={p.id} person={p} selected={sel.has(p.id)} onSelect={() => toggle(p.id)} />)}
          </div>
          <div style={{ height: 30 }}></div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { People, FaceTile, ThresholdPopover });
