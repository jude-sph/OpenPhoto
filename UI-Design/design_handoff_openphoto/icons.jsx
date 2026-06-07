/* icons.jsx — line icon set, SF-Symbols flavored. Usage: <Icon n="timeline" /> */
const ICON_PATHS = {
  timeline: <><rect x="3" y="4" width="18" height="17" rx="2.5"/><path d="M3 9h18M8 2.5v3M16 2.5v3"/><circle cx="8.5" cy="14" r="1.4" fill="currentColor" stroke="none"/><path d="M6 18l3-2.5 2.5 2 3-3L18 18"/></>,
  folders: <><path d="M3 7a2 2 0 0 1 2-2h3.5l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></>,
  folderOpen: <><path d="M3 7a2 2 0 0 1 2-2h3.4l2 2H19a2 2 0 0 1 2 2"/><path d="M3 9.5h17.2a1.5 1.5 0 0 1 1.46 1.86l-1.3 5.2A2 2 0 0 1 18.42 18H5a2 2 0 0 1-2-2z"/></>,
  people: <><circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19a5.5 5.5 0 0 1 11 0"/><path d="M16 6.2a3 3 0 0 1 0 5.6M16.5 19a5.2 5.2 0 0 0-3-4.7"/></>,
  person: <><circle cx="12" cy="8.5" r="3.4"/><path d="M5.5 19.5a6.5 6.5 0 0 1 13 0"/></>,
  map: <><path d="M9 4 3.5 6v14L9 18l6 2 5.5-2V4L15 6 9 4z"/><path d="M9 4v14M15 6v14"/></>,
  mappin: <><path d="M12 21s6.5-5.6 6.5-11A6.5 6.5 0 0 0 5.5 10c0 5.4 6.5 11 6.5 11z"/><circle cx="12" cy="10" r="2.4"/></>,
  bin: <><path d="M4 6.5h16M9 6.5V5a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 5v1.5M6.5 6.5 7.5 19a2 2 0 0 0 2 1.9h5a2 2 0 0 0 2-1.9l1-12.5"/><path d="M10 10.5v6M14 10.5v6"/></>,
  iphone: <><rect x="6.5" y="2.5" width="11" height="19" rx="2.6"/><path d="M10 5h4"/></>,
  sd: <><path d="M7 3.5h7.2L18 7.3V19a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 19V5a1.5 1.5 0 0 1 1-1.5z"/><path d="M9.5 4.5v3M12 4.5v3M14.5 5v2.5"/></>,
  drive: <><rect x="3" y="8" width="18" height="9" rx="2"/><circle cx="7" cy="12.5" r="1.1" fill="currentColor" stroke="none"/><path d="M11 12.5h6"/></>,
  gear: <><circle cx="12" cy="12" r="3.2"/><path d="M12 2.5v2.4M12 19.1v2.4M21.5 12h-2.4M4.9 12H2.5M18.7 5.3l-1.7 1.7M7 17l-1.7 1.7M18.7 18.7 17 17M7 7 5.3 5.3"/></>,
  search: <><circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/></>,
  sliders: <><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2.1"/><circle cx="8" cy="17" r="2.1"/></>,
  heart: <><path d="M12 20s-7-4.4-7-9.4A3.9 3.9 0 0 1 12 7a3.9 3.9 0 0 1 7-2.4c0 5-7 9.4-7 9.4z" transform="translate(0 1)"/></>,
  heartFill: <><path d="M12 20.5s-7.3-4.6-7.3-9.7A4 4 0 0 1 12 7.4a4 4 0 0 1 7.3-1.6c0 5.1-7.3 9.7-7.3 9.7z" fill="currentColor" stroke="none"/></>,
  star: <><path d="m12 3.5 2.6 5.3 5.9.9-4.25 4.1 1 5.85L12 16.9l-5.25 2.75 1-5.85L3.5 9.7l5.9-.9z"/></>,
  starFill: <><path d="m12 3.5 2.6 5.3 5.9.9-4.25 4.1 1 5.85L12 16.9l-5.25 2.75 1-5.85L3.5 9.7l5.9-.9z" fill="currentColor" stroke="none"/></>,
  film: <><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 9.5h4M3 14.5h4M17 9.5h4M17 14.5h4"/></>,
  play: <><path d="M8 5.5v13l11-6.5z" fill="currentColor" stroke="none"/></>,
  live: <><circle cx="12" cy="12" r="3"/><path d="M12 5.5a6.5 6.5 0 0 1 0 13M12 18.5a6.5 6.5 0 0 1 0-13" opacity=".9"/></>,
  cloud: <><path d="M7 18h10a3.5 3.5 0 0 0 .3-7A5 5 0 0 0 7.6 9.6 3.7 3.7 0 0 0 7 18z"/></>,
  driveSlash: <><rect x="3" y="8" width="18" height="9" rx="2"/><circle cx="7" cy="12.5" r="1" fill="currentColor" stroke="none"/><path d="M3 3l18 18" opacity=".9"/></>,
  check: <><path d="m4.5 12.5 5 5 10-11"/></>,
  checkSmall: <><path d="m5 12 4 4 10-10.5"/></>,
  seal: <><path d="m12 3 2.1 1.6 2.6-.3 1 2.4 2.4 1-.3 2.6L22 12l-1.6 2.1.3 2.6-2.4 1-1 2.4-2.6-.3L12 21l-2.1-1.6-2.6.3-1-2.4-2.4-1 .3-2.6L2 12l1.6-2.1-.3-2.6 2.4-1 1-2.4 2.6.3z"/><path d="m9 12 2 2 4-4.5"/></>,
  chevR: <><path d="m9 5 7 7-7 7"/></>,
  chevD: <><path d="m5 9 7 7 7-7"/></>,
  chevL: <><path d="m15 5-7 7 7 7"/></>,
  plus: <><path d="M12 5v14M5 12h14"/></>,
  close: <><path d="M6 6l12 12M18 6 6 18"/></>,
  info: <><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5M12 8h.01"/></>,
  warn: <><path d="M12 3.5 21 19H3z"/><path d="M12 9.5v4.5M12 16.8h.01"/></>,
  sync: <><path d="M20 11a8 8 0 0 0-14-4.5L4 8M4 13a8 8 0 0 0 14 4.5L20 16"/><path d="M4 4v4h4M20 20v-4h-4"/></>,
  camera: <><rect x="3" y="6.5" width="18" height="13" rx="2.5"/><path d="M8.5 6.5 10 4h4l1.5 2.5"/><circle cx="12" cy="13" r="3.4"/></>,
  lens: <><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3.2"/><path d="M12 3.5v3M12 17.5v3M3.5 12h3M17.5 12h3"/></>,
  calendar: <><rect x="3.5" y="5" width="17" height="16" rx="2.5"/><path d="M3.5 10h17M8 3v4M16 3v4"/></>,
  tag: <><path d="M4 4h7l9 9-7 7-9-9z"/><circle cx="8.5" cy="8.5" r="1.4" fill="currentColor" stroke="none"/></>,
  eye: <><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.8"/></>,
  merge: <><path d="M7 4v5a5 5 0 0 0 5 5 5 5 0 0 0 5-5V4M12 14v6"/><path d="m9 17 3 3 3-3"/></>,
  ellipsis: <><circle cx="5" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.6" fill="currentColor" stroke="none"/></>,
  inspector: <><rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M14.5 4.5v15"/></>,
  grid: <><rect x="3.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.5"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.5"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.5"/></>,
  arrowDown: <><path d="M12 4v14M6 12l6 6 6-6"/></>,
  externalDrive: <><rect x="3" y="7" width="18" height="11" rx="2.2"/><circle cx="7.5" cy="12.5" r="1.2" fill="currentColor" stroke="none"/><path d="M11 12.5h6.5"/></>,
  pin: <><path d="M12 21s6-5.2 6-10.3A6 6 0 0 0 6 10.7C6 15.8 12 21 12 21z"/><circle cx="12" cy="10.5" r="2.1"/></>,
  back: <><path d="M15 5l-7 7 7 7"/></>,
  share: <><path d="M12 3v12M8 7l4-4 4 4"/><path d="M5 12v6a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 19 18v-6"/></>,
  rotate: <><path d="M3.5 12a8.5 8.5 0 1 1 2.5 6"/><path d="M3 14v-4h4"/></>,
  crop: <><path d="M6 2v14a2 2 0 0 0 2 2h14M2 6h14a2 2 0 0 1 2 2v14"/></>,
};
function Icon({ n, size, stroke = 1.7, className = "", style }) {
  const p = ICON_PATHS[n];
  if (!p) return null;
  return (
    <span className={"ico " + className} style={style}>
      <svg width={size || 18} height={size || 18} viewBox="0 0 24 24" fill="none"
           stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
        {p}
      </svg>
    </span>
  );
}
Object.assign(window, { Icon, ICON_PATHS });
