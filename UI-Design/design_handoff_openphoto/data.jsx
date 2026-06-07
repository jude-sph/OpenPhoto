/* data.jsx — sample library data for OpenPhoto mock */

const img = (seed, s = 420) => `https://picsum.photos/seed/${seed}/${s}/${s}`;
const imgW = (seed, w = 1280, h = 854) => `https://picsum.photos/seed/${seed}/${w}/${h}`;

const PEOPLE = [
  { id: "p1", name: "Jude", seed: "face-jude", count: 1204 },
  { id: "p2", name: "Mara", seed: "face-mara", count: 863 },
  { id: "p3", name: "Theo", seed: "face-theo", count: 511 },
  { id: "p4", name: "Nan", seed: "face-nan", count: 288 },
  { id: "p5", name: "Sof", seed: "face-sof", count: 174 },
  { id: "p6", name: "Ravi", seed: "face-ravi", count: 132 },
  // unnamed clusters
  { id: "u1", name: null, seed: "face-u1", count: 96, conf: 0.94 },
  { id: "u2", name: null, seed: "face-u2", count: 71, conf: 0.88 },
  { id: "u3", name: null, seed: "face-u3", count: 54, conf: 0.81 },
  { id: "u4", name: null, seed: "face-u4", count: 41, conf: 0.77 },
  { id: "u5", name: null, seed: "face-u5", count: 33, conf: 0.69 },
  { id: "u6", name: null, seed: "face-u6", count: 22, conf: 0.63 },
  { id: "u7", name: null, seed: "face-u7", count: 14, conf: 0.55 },
  { id: "u8", name: null, seed: "face-u8", count: 9, conf: 0.48 },
];

// folder tree (status: 'synced' | 'local' | 'offline')
const FOLDERS = [
  { path: "2025", name: "2025", status: "synced", open: true, depth: 0, kids: ["2025/lisbon25", "2025/screenshots", "2025/canada23"] },
  { path: "2025/lisbon25", name: "lisbon25", status: "synced", depth: 1, count: 642 },
  { path: "2025/screenshots", name: "mac-screenshots", status: "local", depth: 1, count: 1880 },
  { path: "2025/film-scans", name: "film-scans", status: "offline", depth: 1, count: 214 },
  { path: "2024", name: "2024", status: "synced", open: true, depth: 0 },
  { path: "2024/canada23", name: "2023/canada23", status: "synced", depth: 1, count: 388 },
  { path: "2024/birthdays", name: "birthdays", status: "local", depth: 1, count: 96 },
  { path: "2022", name: "2022", status: "synced", open: true, depth: 0 },
  { path: "2022/rome2022", name: "rome2022", status: "synced", depth: 1, count: 524 },
  { path: "2022/wedding", name: "wedding-raw", status: "offline", depth: 1, count: 1342 },
  { path: "inbox", name: "_inbox", status: "local", depth: 0, count: 47 },
];

const CAMERAS = [
  { c: "iPhone 15 Pro", l: "Main · 24 mm ƒ1.78", iso: 64, f: "1.8", sh: "1/120", mm: "24" },
  { c: "Canon EOS R6", l: "RF 35 mm ƒ1.8 Macro", iso: 200, f: "2.2", sh: "1/250", mm: "35" },
  { c: "Fujifilm X100V", l: "23 mm ƒ2", iso: 320, f: "2.8", sh: "1/400", mm: "23" },
  { c: "iPhone 13", l: "Wide · 26 mm ƒ1.6", iso: 100, f: "1.6", sh: "1/60", mm: "26" },
];

const PLACES = [
  { label: "Lisbon, Portugal", lat: 38.71, lng: -9.14 },
  { label: "Cascais", lat: 38.70, lng: -9.42 },
  { label: "Banff, Canada", lat: 51.18, lng: -115.57 },
  { label: "Rome, Italy", lat: 41.90, lng: 12.50 },
  { label: "Brooklyn, NY", lat: 40.68, lng: -73.94 },
  { label: "Home", lat: 40.71, lng: -74.01 },
];

// Build timeline day-groups. Each item gets a global id.
let _id = 0;
function mk(seed, opts = {}) {
  _id += 1;
  const cam = CAMERAS[opts.cam ?? 0];
  const place = PLACES[opts.pl ?? 0];
  return {
    id: "i" + _id, seed,
    type: opts.type || "photo",
    dur: opts.dur || null,
    offline: !!opts.offline,
    fav: !!opts.fav,
    people: opts.people || [],
    folder: opts.folder || "2025/lisbon25",
    place: place.label, lat: place.lat, lng: place.lng,
    camera: cam.c, lens: cam.l,
    exif: { iso: cam.iso, f: cam.f, sh: cam.sh, mm: cam.mm },
    caption: opts.caption || "",
    rating: opts.rating || 0,
    tags: opts.tags || [],
    presence: opts.presence || { mac: true, t7: true, backup: opts.offline ? false : true },
  };
}

const TIMELINE = [
  {
    date: "Friday, June 6", sub: "", place: "Cascais", year: 2025, month: "Jun",
    items: [
      mk("op-sea1", { pl: 1, fav: true, people: ["p1", "p2"], cam: 0 }),
      mk("op-sea2", { pl: 1, type: "live" }),
      mk("op-sea3", { pl: 1, type: "video", dur: "0:24" }),
      mk("op-sea4", { pl: 1, people: ["p3"] }),
      mk("op-sea5", { pl: 1, fav: true }),
      mk("op-sea6", { pl: 1, offline: true }),
      mk("op-sea7", { pl: 1 }),
    ],
  },
  {
    date: "Tuesday, June 3", sub: "", place: "Lisbon, Portugal", year: 2025, month: "Jun",
    items: [
      mk("op-lx1", { fav: true, people: ["p1"], cam: 2 }),
      mk("op-lx2", { type: "live" }),
      mk("op-lx3", {}),
      mk("op-lx4", { people: ["p2", "p5"] }),
      mk("op-lx5", { type: "video", dur: "1:08" }),
      mk("op-lx6", { offline: true }),
      mk("op-lx7", {}),
      mk("op-lx8", { fav: true }),
      mk("op-lx9", {}),
      mk("op-lx10", { offline: true }),
      mk("op-lx11", {}),
      mk("op-lx12", { people: ["p1", "p2", "p3"] }),
    ],
  },
  {
    date: "May 2025", sub: "312 items", place: "Lisbon · Sintra", year: 2025, month: "May",
    items: [
      mk("op-m1", { type: "live", fav: true }), mk("op-m2", {}), mk("op-m3", { people: ["p4"] }),
      mk("op-m4", { offline: true }), mk("op-m5", {}), mk("op-m6", { type: "video", dur: "0:11" }),
      mk("op-m7", {}), mk("op-m8", { fav: true }), mk("op-m9", { offline: true }), mk("op-m10", {}),
      mk("op-m11", { people: ["p1"] }), mk("op-m12", {}), mk("op-m13", {}), mk("op-m14", { offline: true }),
    ],
  },
  {
    date: "March 12, 2024", sub: "", place: "Banff, Canada", year: 2024, month: "Mar",
    items: [
      mk("op-b1", { pl: 2, fav: true, cam: 1, folder: "2024/canada23" }),
      mk("op-b2", { pl: 2, type: "video", dur: "2:31", folder: "2024/canada23" }),
      mk("op-b3", { pl: 2, people: ["p1", "p2"], folder: "2024/canada23" }),
      mk("op-b4", { pl: 2, offline: true, folder: "2024/canada23" }),
      mk("op-b5", { pl: 2, fav: true, folder: "2024/canada23" }),
      mk("op-b6", { pl: 2, folder: "2024/canada23" }),
      mk("op-b7", { pl: 2, type: "live", folder: "2024/canada23" }),
      mk("op-b8", { pl: 2, offline: true, folder: "2024/canada23" }),
    ],
  },
  {
    date: "September 2022", sub: "524 items", place: "Rome, Italy", year: 2022, month: "Sep",
    items: [
      mk("op-r1", { pl: 3, fav: true, cam: 1, folder: "2022/rome2022", people: ["p1", "p2"] }),
      mk("op-r2", { pl: 3, folder: "2022/rome2022" }),
      mk("op-r3", { pl: 3, type: "video", dur: "0:48", folder: "2022/rome2022" }),
      mk("op-r4", { pl: 3, offline: true, folder: "2022/rome2022" }),
      mk("op-r5", { pl: 3, folder: "2022/rome2022", fav: true }),
      mk("op-r6", { pl: 3, folder: "2022/rome2022" }),
      mk("op-r7", { pl: 3, type: "live", folder: "2022/rome2022" }),
      mk("op-r8", { pl: 3, offline: true, folder: "2022/rome2022" }),
      mk("op-r9", { pl: 3, folder: "2022/rome2022" }),
      mk("op-r10", { pl: 3, folder: "2022/rome2022" }),
    ],
  },
];

const YEARS = [2025, 2024, 2023, 2022];

// flat lookup
const ALL_PHOTOS = TIMELINE.flatMap((g) => g.items);
const byId = (id) => ALL_PHOTOS.find((p) => p.id === id);

// folder grid (lisbon25 selected)
const FOLDER_GRID = TIMELINE[1].items.concat(TIMELINE[2].items).slice(0, 18);

// import candidates (from iPhone) — larger thumbs, some already-in-library
const IMPORT_ITEMS = Array.from({ length: 15 }).map((_, i) => ({
  id: "imp" + i, seed: "op-imp" + i,
  type: i % 7 === 3 ? "video" : (i % 5 === 0 ? "live" : "photo"),
  dur: i % 7 === 3 ? "0:1" + i : null,
  dupe: [2, 6, 11].includes(i),
  sel: ![2, 6, 11].includes(i),
}));

// map pin clusters
const MAP_PINS = [
  { id: "mp1", x: 40, y: 54, n: 642, label: "Lisbon", seed: "op-lx1" },
  { id: "mp2", x: 32, y: 67, n: 88, label: "Cascais", seed: "op-sea1" },
  { id: "mp3", x: 16, y: 26, n: 388, label: "Banff", seed: "op-b1" },
  { id: "mp4", x: 56, y: 45, n: 524, label: "Rome", seed: "op-r1" },
  { id: "mp5", x: 19, y: 47, n: 1204, label: "Brooklyn", seed: "op-m2" },
  { id: "mp6", x: 47, y: 71, n: 47, label: "Marrakesh", seed: "op-m6" },
  { id: "mp7", x: 79, y: 35, n: 132, label: "Tokyo", seed: "op-m9" },
];

Object.assign(window, {
  img, imgW, PEOPLE, FOLDERS, CAMERAS, PLACES, TIMELINE, YEARS,
  ALL_PHOTOS, byId, FOLDER_GRID, IMPORT_ITEMS, MAP_PINS,
});
