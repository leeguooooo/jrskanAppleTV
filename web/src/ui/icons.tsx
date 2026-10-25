// Stroke icons (24×24, currentColor), Lucide-style.
const paths = {
  search: "M11 19a8 8 0 1 1 0-16 8 8 0 0 1 0 16Zm10 2-4.35-4.35",
  refresh: "M21 12a9 9 0 1 1-2.64-6.36M21 3v6h-6",
  settings: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3a7.4 7.4 0 0 0-.1-1.2l2-1.6-2-3.4-2.4 1a7.5 7.5 0 0 0-2-1.2L14.5 3h-5l-.4 2.6a7.5 7.5 0 0 0-2 1.2l-2.4-1-2 3.4 2 1.6a7.4 7.4 0 0 0 0 2.4l-2 1.6 2 3.4 2.4-1a7.5 7.5 0 0 0 2 1.2l.4 2.6h5l.4-2.6a7.5 7.5 0 0 0 2-1.2l2.4 1 2-3.4-2-1.6c.07-.4.1-.8.1-1.2Z",
  back: "m15 18-6-6 6-6",
  chevron: "m9 18 6-6-6-6",
  play: "M7 4v16l13-8Z",
  star: "m12 3 2.8 5.7 6.2.9-4.5 4.4 1 6.2L12 17.3 6.5 20.2l1-6.2L3 9.6l6.2-.9Z",
  flame: "M12 22c4 0 7-2.7 7-7 0-3-1.6-5.4-3.5-7.4-.3 1.9-1.2 3.2-2.5 3.9.2-3.4-1.3-6.6-4-9.5C8.6 5.8 5 9 5 15c0 4.3 3 7 7 7Z",
  clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-13v4l3 2",
  fullscreen: "M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5",
  pip: "M3 5h18v14H3ZM12 12h7v5h-7Z",
  list: "M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01",
  close: "M18 6 6 18M6 6l12 12",
  chat: "M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12Z",
  chart: "M4 20V10M10 20V4M16 20v-7M22 20H2",
  volume: "M11 5 6 9H3v6h3l5 4ZM16 9a4 4 0 0 1 0 6M19 6a8 8 0 0 1 0 12",
  mute: "M11 5 6 9H3v6h3l5 4ZM22 9l-6 6M16 9l6 6",
  external: "M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5",
} as const;

export type IconName = keyof typeof paths;

export function Icon({ name, filled = false }: { name: IconName; filled?: boolean }) {
  return (
    <svg viewBox="0 0 24 24" fill={filled ? "currentColor" : "none"} stroke="currentColor" stroke-width="2"
      stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d={paths[name]} />
    </svg>
  );
}
