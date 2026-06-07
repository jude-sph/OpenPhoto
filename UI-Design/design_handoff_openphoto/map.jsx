/* map.jsx — clustered photo pins + region strip */

function MapScreen({ onOpen }) {
  const [active, setActive] = React.useState(MAP_PINS[0]);
  const stripPhotos = ALL_PHOTOS.slice(0, 12);

  return (
    <div className="content">
      <div className="toolbar">
        <div className="tb-title">Map</div>
        <div className="tb-sub" style={{ marginLeft: 6 }}>3,029 photos placed · 38 regions</div>
        <div className="tb-spacer"></div>
        <div className="search">
          <Icon n="search" size={14} />
          <input placeholder="Search places…" />
        </div>
      </div>

      <div className="map-stage">
        <div className="map-canvas">
          <div className="map-graticule"></div>
          <div className="map-land l1"></div>
          <div className="map-land l2"></div>
          <div className="map-land l3"></div>
          {MAP_PINS.map((pin) => (
            <button key={pin.id}
                    className={"map-pin" + (active.id === pin.id ? " on" : "")}
                    style={{ left: pin.x + "%", top: pin.y + "%" }}
                    onClick={() => setActive(pin)}>
              <span className="map-pin-thumb"><img src={img(pin.seed, 120)} alt="" draggable="false" /></span>
              <span className="map-pin-count tnum">{pin.n.toLocaleString()}</span>
            </button>
          ))}
          <div className="map-controls">
            <button className="iconbtn"><Icon n="plus" size={15} /></button>
            <button className="iconbtn"><Icon n="chevD" size={15} /></button>
          </div>
        </div>

        <div className="map-strip">
          <div className="map-strip-head">
            <Icon n="mappin" size={15} className="muted" />
            <span style={{ fontWeight: 650, fontSize: 14 }}>{active.label}</span>
            <span className="faint tnum" style={{ fontSize: 12.5 }}>{active.n.toLocaleString()} photos · Sep 2022 – Jun 2025</span>
            <div className="tb-spacer"></div>
            <button className="chip" onClick={() => {}}>Open in Timeline <Icon n="chevR" size={12} /></button>
          </div>
          <div className="map-strip-row">
            {stripPhotos.map((p) => (
              <div key={p.id} className="strip-thumb" onClick={() => onOpen(p)}>
                <img src={img(p.seed, 160)} alt="" draggable="false" />
                {p.type === "video" && <span className="strip-play"><Icon n="play" size={12} /></span>}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { MapScreen });
