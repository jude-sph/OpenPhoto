/* timeline.jsx — hero screen: grouped virtualized-feel grid, sticky heads, year scrubber */

function FilterChips({ filters, setFilters }) {
  const defs = [
    { k: "people", icon: "person", label: "People" },
    { k: "places", icon: "mappin", label: "Places" },
    { k: "fav", icon: "heart", label: "Favorites" },
    { k: "media", icon: "film", label: "Media type" },
  ];
  return (
    <div style={{ display: "flex", gap: 7 }}>
      {defs.map((d) => (
        <button key={d.k} className={"chip" + (filters[d.k] ? " on" : "")}
                onClick={() => setFilters((f) => ({ ...f, [d.k]: !f[d.k] }))}>
          <span className="chip-ico"><Icon n={d.icon} size={14} /></span>{d.label}
        </button>
      ))}
    </div>
  );
}

function GridSizeSlider({ cell, setCell }) {
  return (
    <div className="gridsize" title="Thumbnail size">
      <Icon n="grid" size={12} />
      <input type="range" min="92" max="220" value={cell} onChange={(e) => setCell(+e.target.value)} />
    </div>
  );
}

function Scrubber({ years, active }) {
  return (
    <div className="scrubber">
      {years.map((y) => (
        <span key={y} className={"scrub-yr" + (y === active ? " on" : "")}>{y}</span>
      ))}
    </div>
  );
}

function Timeline({ onOpen, cell, setCell }) {
  const [filters, setFilters] = React.useState({});
  const [activeYear, setActiveYear] = React.useState(2025);
  const scrollRef = React.useRef(null);

  const onScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    const heads = el.querySelectorAll("[data-year]");
    let cur = 2025;
    heads.forEach((h) => {
      if (h.getBoundingClientRect().top < el.getBoundingClientRect().top + 80) cur = +h.dataset.year;
    });
    setActiveYear(cur);
  };

  return (
    <div className="content">
      <div className="toolbar">
        <div className="tb-title">Timeline</div>
        <div className="tb-sub" style={{ marginLeft: 4 }}>58,212 photos · 4,108 videos</div>
        <div className="tb-spacer"></div>
        <FilterChips filters={filters} setFilters={setFilters} />
        <div style={{ width: 1, height: 22, background: "var(--hair)", margin: "0 4px" }}></div>
        <GridSizeSlider cell={cell} setCell={setCell} />
        <div className="search">
          <Icon n="search" size={14} />
          <input placeholder="Search by place, person, thing…" />
        </div>
      </div>

      <div className="scroll" ref={scrollRef} onScroll={onScroll}>
        {TIMELINE.map((g, gi) => (
          <div key={gi} data-year={g.year}>
            <div className="day-head">
              <span className="day-title">{g.date}</span>
              {g.sub && <span className="day-sub">{g.sub}</span>}
              {g.place && <span className="day-place"><Icon n="mappin" size={13} />{g.place}</span>}
            </div>
            <div className="grid" style={{ "--cell": cell + "px" }}>
              {g.items.map((p) => (
                <PhotoCell key={p.id} p={p} onClick={() => onOpen(p)} />
              ))}
            </div>
          </div>
        ))}
        <div style={{ height: 30 }}></div>
        <Scrubber years={YEARS} active={activeYear} />
      </div>
    </div>
  );
}

Object.assign(window, { Timeline, FilterChips, GridSizeSlider, Scrubber });
