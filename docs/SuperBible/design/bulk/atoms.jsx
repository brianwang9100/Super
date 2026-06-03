// bulk/atoms.jsx — bulk-annotation specific atoms, layered on top of
// annotations/atoms.jsx (ANNO_THEMES, Phone, StatusBar, AnnotationBubble,
// AI, CATEGORIES, CategoryBadge). These cover the parts the single-verse
// flow doesn't: progress (ring + bar), per-chapter status rows, scope
// pickers, and background job cards.
//
// Conventions carried over: 24×24 icon grid · 1.6 stroke · single accent,
// no rainbow. The one exception is a dedicated *failure* hue — a muted red
// reserved strictly for the "couldn't generate / retry" state, matching the
// danger colour already used in annotations/sheet.jsx's card menu.

// ──────────────────────────────────────────────────────────
// Failure hue — the only colour outside the accent family. Soft tile +
// ink, tuned per theme so it stays muted (never alarm-red).
// ──────────────────────────────────────────────────────────
function failInk(t)  { return t.isDark ? 'oklch(0.72 0.14 28)' : 'oklch(0.55 0.18 27)'; }
function failSoft(t) { return t.isDark ? 'oklch(0.33 0.07 27)' : 'oklch(0.93 0.045 30)'; }

// ──────────────────────────────────────────────────────────
// Extra icons for the bulk surfaces. AI (from annotations/atoms) already
// gives us Close, Kebab, Sparkle, Refresh, Book, Check, Send, ChevronDown.
// ──────────────────────────────────────────────────────────
const BI = {
  Pause: ({ s = 16, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill={c} stroke="none">
      <rect x="6.5" y="5" width="3.4" height="14" rx="1.2" />
      <rect x="14.1" y="5" width="3.4" height="14" rx="1.2" />
    </svg>
  ),
  Play: ({ s = 16, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill={c} stroke="none">
      <path d="M7 5.5v13a1 1 0 0 0 1.5.87l11-6.5a1 1 0 0 0 0-1.74l-11-6.5A1 1 0 0 0 7 5.5z" />
    </svg>
  ),
  Stop: ({ s = 16, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill={c} stroke="none">
      <rect x="6" y="6" width="12" height="12" rx="2.4" />
    </svg>
  ),
  Layers: ({ s = 16, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3l9 5-9 5-9-5 9-5z" />
      <path d="M3 13l9 5 9-5" />
    </svg>
  ),
  ChevronRight: ({ s = 14, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9 6l6 6-6 6" />
    </svg>
  ),
  CheckCircle: ({ s = 16, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill={c} stroke="none">
      <circle cx="12" cy="12" r="10" />
      <path d="M7.5 12.4l3 3 6-6.4" fill="none" stroke="#fff" strokeWidth="2.1"
        strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ),
  Alert: ({ s = 16, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3.4l9.2 16a1 1 0 0 1-.87 1.5H3.67a1 1 0 0 1-.87-1.5l9.2-16z" />
      <path d="M12 9.5v4.2" />
      <circle cx="12" cy="17.2" r="0.4" fill={c} stroke={c} strokeWidth="1.2" />
    </svg>
  ),
  Clock: ({ s = 14, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="8.4" />
      <path d="M12 7.6V12l3 1.8" />
    </svg>
  ),
  Back: ({ s = 18, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="M15 6l-6 6 6 6" />
    </svg>
  ),
  // Annotation glyph for the settings row — speech bubble with the
  // three generating-dots, echoing AnnotationBubble.
  Bubble: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 4h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-8.5l-3.5 3v-3H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z" />
      <circle cx="9" cy="10" r="0.5" fill={c} stroke={c} strokeWidth="1.1" />
      <circle cx="12" cy="10" r="0.5" fill={c} stroke={c} strokeWidth="1.1" />
      <circle cx="15" cy="10" r="0.5" fill={c} stroke={c} strokeWidth="1.1" />
    </svg>
  ),
  Tag: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3.5 12.5l8 8 9-9V4.5H13z" />
      <circle cx="16.5" cy="8" r="1.1" />
    </svg>
  ),
  Globe: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="9" />
      <path d="M3 12h18M12 3c2.6 2.4 4 5.6 4 9s-1.4 6.6-4 9c-2.6-2.4-4-5.6-4-9s1.4-6.6 4-9z" />
    </svg>
  ),
  // ── Settings-root glyphs (match the real Settings screen) ──
  Stack: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3l9 4.8-9 4.8-9-4.8L12 3z" />
      <path d="M3 12l9 4.8L21 12" />
      <path d="M3 16.5l9 4.8 9-4.8" />
    </svg>
  ),
  Moon: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 14.2A8.2 8.2 0 0 1 9.8 4 8.4 8.4 0 1 0 20 14.2z" />
    </svg>
  ),
  Lines: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 6h16M4 12h11M4 18h7" />
    </svg>
  ),
  Branch: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="7" cy="6" r="2.4" /><circle cx="7" cy="18" r="2.4" /><circle cx="17" cy="9" r="2.4" />
      <path d="M7 8.4v7.2M9.3 8.2c3.4.5 5.4 1.6 5.7 4.6" />
    </svg>
  ),
  Wrench: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M15.5 4.5a4.5 4.5 0 0 0-5.9 5.6l-5.3 5.3a1.7 1.7 0 0 0 2.4 2.4l5.3-5.3a4.5 4.5 0 0 0 5.6-5.9l-2.6 2.6-2.1-2.1 2.6-2.6z" />
    </svg>
  ),
  Compact: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 7h16M4 17h16" />
      <path d="M9 10.5L12 13l3-2.5M9 13.5L12 11l3 2.5" />
    </svg>
  ),
  Database: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <ellipse cx="12" cy="5.5" rx="7" ry="2.6" />
      <path d="M5 5.5v13c0 1.4 3.1 2.6 7 2.6s7-1.2 7-2.6v-13M5 12c0 1.4 3.1 2.6 7 2.6s7-1.2 7-2.6" />
    </svg>
  ),
  Info: ({ s = 20, c = 'currentColor' }) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none"
      stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="9" />
      <path d="M12 11v5" /><circle cx="12" cy="8" r="0.5" fill={c} stroke={c} strokeWidth="1.2" />
    </svg>
  ),
};

// ──────────────────────────────────────────────────────────
// ProgressRing — circular determinate progress. Track in bgSunken,
// fill in accent (or a passed colour). Optional center child.
// ──────────────────────────────────────────────────────────
function ProgressRing({ t, value = 0, size = 46, stroke = 4, color, track, children }) {
  const r = (size - stroke) / 2;
  const circ = 2 * Math.PI * r;
  const col = color || t.accent;
  return (
    <span style={{
      position: 'relative', width: size, height: size,
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      flexShrink: 0,
    }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}
        style={{ position: 'absolute', inset: 0 }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none"
          stroke={track || t.bgSunken} strokeWidth={stroke} />
        <circle cx={size / 2} cy={size / 2} r={r} fill="none"
          stroke={col} strokeWidth={stroke} strokeLinecap="round"
          strokeDasharray={circ} strokeDashoffset={circ * (1 - Math.max(0, Math.min(1, value)))}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
          style={{ transition: 'stroke-dashoffset 400ms ease' }} />
      </svg>
      {children}
    </span>
  );
}

// ──────────────────────────────────────────────────────────
// ProgressBar — slim determinate track. Indeterminate when value is null
// (renders a small moving segment via CSS class .bulk-indet).
// ──────────────────────────────────────────────────────────
function ProgressBar({ t, value = 0, height = 6, color }) {
  const col = color || t.accent;
  return (
    <div style={{
      width: '100%', height, borderRadius: 99,
      background: t.bgSunken, overflow: 'hidden', position: 'relative',
    }}>
      {value == null ? (
        <div className="bulk-indet" style={{
          position: 'absolute', top: 0, bottom: 0, width: '40%',
          borderRadius: 99, background: col,
        }} />
      ) : (
        <div style={{
          height: '100%', width: `${Math.max(0, Math.min(1, value)) * 100}%`,
          borderRadius: 99, background: col,
          transition: 'width 400ms ease',
        }} />
      )}
    </div>
  );
}

// ──────────────────────────────────────────────────────────
// Status leaf — the small left-edge marker on a chapter row.
//   queued    → empty bubble (faint)
//   gen       → spinning ring (indeterminate)
//   done      → solid filled bubble (accent)
//   failed    → alert glyph in failure hue
// Mirrors the AnnotationBubble vocabulary so a row reads the same as the
// reader's verse-end bubble.
// ──────────────────────────────────────────────────────────
function StatusLeaf({ t, state, size = 22 }) {
  if (state === 'done')
    return <AnnotationBubble t={t} state="filled" size={size} />;
  if (state === 'queued')
    return <AnnotationBubble t={t} state="empty" size={size} />;
  if (state === 'failed')
    return (
      <span style={{
        width: size, height: size, display: 'inline-flex',
        alignItems: 'center', justifyContent: 'center',
      }}><BI.Alert s={size - 4} c={failInk(t)} /></span>
    );
  // gen → spinner ring
  return (
    <span className="bulk-spin" style={{
      width: size, height: size, display: 'inline-flex',
      alignItems: 'center', justifyContent: 'center',
    }}>
      <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="9" stroke={t.bgSunken} strokeWidth="2.6" />
        <path d="M12 3a9 9 0 0 1 9 9" stroke={t.accent} strokeWidth="2.6"
          strokeLinecap="round" fill="none" />
      </svg>
    </span>
  );
}

// ──────────────────────────────────────────────────────────
// ChapterRow — one line in the bulk progress list.
//   { n, state, count? }   count = annotations produced (done state)
// ──────────────────────────────────────────────────────────
function ChapterRow({ t, n, state, count, onRetry }) {
  const dim = state === 'queued';
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '11px 4px',
      borderBottom: `0.5px solid ${t.borderFaint}`,
      opacity: dim ? 0.78 : 1,
    }}>
      <StatusLeaf t={t} state={state} size={22} />
      <div style={{
        flex: 1, minWidth: 0,
        fontSize: 15, color: state === 'queued' ? t.inkSoft : t.ink,
        fontWeight: state === 'gen' ? 600 : 500,
      }}>
        Romans {n}
      </div>

      {/* Right cell — varies by state */}
      {state === 'done' && (
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
          <AnnotationBubble t={t} state="filled" size={12} />
          <span className="mono" style={{ fontSize: 11.5, color: t.inkFaint, letterSpacing: 0.2 }}>{count}</span>
        </span>
      )}
      {state === 'gen' && (
        <span className="mono" style={{ fontSize: 11.5, color: t.accent, letterSpacing: 0.2 }}>
          generating
        </span>
      )}
      {state === 'queued' && (
        <span className="mono" style={{ fontSize: 11.5, color: t.inkMute, letterSpacing: 0.2 }}>
          queued
        </span>
      )}
      {state === 'failed' && (
        <button style={{
          display: 'inline-flex', alignItems: 'center', gap: 5,
          background: failSoft(t), color: failInk(t),
          border: 'none', cursor: 'pointer',
          padding: '5px 11px', borderRadius: 99,
          fontFamily: 'inherit', fontSize: 12, fontWeight: 600,
        }}>
          <AI.Refresh s={12} c={failInk(t)} /> Retry
        </button>
      )}
    </div>
  );
}

// Build a chapter list for Romans (16ch). doneCount chapters are complete,
// the next is generating, the rest queued. failAt (1-based) marks one row
// as failed instead of done.
function romansChapters({ doneCount = 0, failAt = null, generating = true, total = 16 }) {
  // deterministic-ish per-chapter note counts
  const NOTES = [9, 14, 11, 16, 12, 8, 13, 18, 10, 15, 7, 12, 9, 11, 14, 6];
  const rows = [];
  for (let n = 1; n <= total; n++) {
    let state;
    if (failAt === n) state = 'failed';
    else if (n <= doneCount) state = 'done';
    else if (n === doneCount + 1 && generating) state = 'gen';
    else state = 'queued';
    rows.push({ n, state, count: NOTES[(n - 1) % NOTES.length] });
  }
  return rows;
}

// ══════════════════════════════════════════════════════════
// SETTINGS VOCABULARY — themed mirrors of the app's real SettingsModal
// (src/settings.jsx): sheet-from-top chrome, grouped cards, rows, switch,
// uppercase section labels. Re-implemented against the explicit `t` theme
// so the spec stays self-contained and switchable across all three themes.
// ══════════════════════════════════════════════════════════

// SettingsScaffold — the sheet chrome inside a Phone. Peeks the reader +
// scrim behind (matching SettingsModal's top:40 presentation). `leading`
// is 'back' or 'close'.
function SettingsScaffold({ t, title, leading = 'back', children, footer }) {
  return (
    <Phone t={t}>
      <StatusBar t={t} />
      <ReaderGhost t={t} opacity={0.16} />
      <div style={{ position: 'absolute', inset: 0, background: t.scrim }} />
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0, top: 30,
        background: t.bg, borderTopLeftRadius: 22, borderTopRightRadius: 22,
        display: 'flex', flexDirection: 'column', overflow: 'hidden',
        boxShadow: t.isDark ? '0 -8px 30px rgba(0,0,0,0.5)' : '0 -8px 30px rgba(40,60,50,0.14)',
      }}>
        <div style={{
          display: 'flex', alignItems: 'center', padding: '13px 14px', flexShrink: 0,
          borderBottom: `0.5px solid ${t.borderFaint}`,
        }}>
          <button style={settingsIconBtn(t)}>
            {leading === 'back' ? <BI.Back s={17} c={t.ink} /> : <AI.Close s={15} c={t.ink} />}
          </button>
          <div style={{ flex: 1, textAlign: 'center', fontSize: 16, fontWeight: 600, color: t.ink }}>{title}</div>
          <div style={{ width: 32 }} />
        </div>
        <div className="nice-scroll" style={{ flex: 1, overflowY: 'auto' }}>{children}</div>
        {footer && (
          <div style={{
            flexShrink: 0, borderTop: `0.5px solid ${t.borderFaint}`,
            background: t.bg, padding: '12px 16px 16px',
          }}>{footer}</div>
        )}
      </div>
    </Phone>
  );
}

function settingsIconBtn(t) {
  return {
    width: 32, height: 32, borderRadius: 99, flexShrink: 0,
    background: t.bgRaised, border: `0.5px solid ${t.borderFaint}`,
    color: t.ink, cursor: 'pointer',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
  };
}

// SGroup — the rounded grouped card.
function SGroup({ t, children, style }) {
  return (
    <div style={{
      margin: '0 16px 14px', borderRadius: 14,
      background: t.bgRaised, border: `0.5px solid ${t.borderFaint}`,
      overflow: 'hidden', ...style,
    }}>{children}</div>
  );
}

// SectionLabel — uppercase group caption.
function SectionLabel({ t, children, style }) {
  return (
    <div className="mono" style={{
      fontSize: 10.5, letterSpacing: 0.8, textTransform: 'uppercase',
      color: t.inkFaint, fontWeight: 500, padding: '4px 20px 8px', ...style,
    }}>{children}</div>
  );
}

// SRow — one settings line. icon · label · value · trailing (chevron / right).
function SRow({ t, icon, label, sub, value, right, chevron = true, danger, last, onTop }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 13, width: '100%',
      padding: '13px 16px', textAlign: 'left',
      borderBottom: last ? 'none' : `0.5px solid ${t.borderFaint}`,
    }}>
      {icon && <span style={{ color: danger ? failInk(t) : t.inkSoft, display: 'flex', flexShrink: 0 }}>{icon}</span>}
      <span style={{ flex: 1, minWidth: 0 }}>
        <span style={{ display: 'block', fontSize: 15.5, color: danger ? failInk(t) : t.ink }}>{label}</span>
        {sub && <span style={{ display: 'block', fontSize: 12.5, color: t.inkFaint, marginTop: 1 }}>{sub}</span>}
      </span>
      {value && <span style={{ fontSize: 14, color: t.inkFaint, flexShrink: 0 }}>{value}</span>}
      {right !== undefined ? right : (chevron && <BI.ChevronRight s={14} c={t.inkMute} />)}
    </div>
  );
}

// Switch — themed iOS toggle.
function Switch({ t, on }) {
  return (
    <span style={{
      width: 44, height: 26, borderRadius: 99, padding: 2, flexShrink: 0,
      background: on ? t.accent : t.border, display: 'inline-block', position: 'relative',
    }}>
      <span style={{
        display: 'block', width: 22, height: 22, borderRadius: 99,
        background: '#fff', transform: `translateX(${on ? 18 : 0}px)`,
        boxShadow: '0 1px 2px rgba(0,0,0,0.2)',
      }} />
    </span>
  );
}

// ──────────────────────────────────────────────────────────
// CoverageCard — the synopsis at the top of the Annotations pane. Honest
// three-level breakdown of how much of the Bible carries annotations:
// books · chapters · verses. No invented fullness, no note counts.
// ──────────────────────────────────────────────────────────
function CoverageStat({ t, value, total, label, last }) {
  return (
    <div style={{
      flex: 1, padding: '4px 8px', textAlign: 'center',
      borderLeft: last ? 'none' : `0.5px solid ${t.borderFaint}`,
    }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'center', gap: 3 }}>
        <span className="mono" style={{ fontSize: 21, fontWeight: 600, color: t.ink, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{value}</span>
        <span className="mono" style={{ fontSize: 11, color: t.inkMute }}>/{total}</span>
      </div>
      <div className="mono" style={{ fontSize: 9.5, color: t.inkFaint, letterSpacing: 0.5, textTransform: 'uppercase', marginTop: 6 }}>{label}</div>
    </div>
  );
}

function CoverageCard({ t, books = 3, totalBooks = 66, chapters = 38, totalChapters = '1,189', verses = '1,204', totalVerses = '31,102' }) {
  return (
    <div style={{
      margin: '4px 16px 16px', padding: '14px 8px 12px', borderRadius: 16,
      background: t.bgRaised, border: `0.5px solid ${t.borderFaint}`,
    }}>
      <div className="mono" style={{ fontSize: 10, letterSpacing: 0.8, textTransform: 'uppercase', color: t.inkFaint, fontWeight: 500, padding: '0 8px 10px' }}>Annotated</div>
      <div style={{ display: 'flex' }}>
        <CoverageStat t={t} value={books} total={totalBooks} label="books" />
        <CoverageStat t={t} value={chapters} total={totalChapters} label="chapters" />
        <CoverageStat t={t} value={verses} total={totalVerses} label="verses" last />
      </div>
    </div>
  );
}

// ──────────────────────────────────────────────────────────
// Selection atoms — book list that expands to chapters (no testament
// grouping). A fully-annotated book or chapter shows a "Done" badge.
// ──────────────────────────────────────────────────────────
function CheckBox({ t, checked, partial }) {
  return (
    <span style={{
      width: 21, height: 21, borderRadius: 6, flexShrink: 0,
      background: checked ? t.accent : 'transparent',
      border: checked ? 'none' : `1.5px solid ${t.inkMute}`,
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    }}>
      {checked && <AI.Check s={13} c={t.accentInk} />}
      {!checked && partial && <span style={{ width: 9, height: 2.5, borderRadius: 2, background: t.inkMute }} />}
    </span>
  );
}

function DoneBadge({ t }) {
  return (
    <span className="mono" style={{
      fontSize: 9.5, letterSpacing: 0.4, textTransform: 'uppercase',
      color: t.accent, fontWeight: 600,
      display: 'inline-flex', alignItems: 'center', gap: 4,
    }}><AnnotationBubble t={t} state="filled" size={11} /> Done</span>
  );
}

// BookCheckRow — selectable book; chevron rotates when expanded. `done`
// = whole book annotated; `partial` = some chapters done.
function BookCheckRow({ t, name, chapters, checked, done, partial, expanded, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, width: '100%',
      padding: '12px 14px', textAlign: 'left',
      borderBottom: last ? 'none' : `0.5px solid ${t.borderFaint}`,
    }}>
      <CheckBox t={t} checked={checked} partial={partial} />
      <span style={{ flex: 1, minWidth: 0, fontSize: 15.5, color: t.ink, fontWeight: 500 }}>{name}</span>
      {done && <DoneBadge t={t} />}
      {!done && partial && (
        <span className="mono" style={{ fontSize: 10.5, color: t.accent, fontWeight: 600 }}>partial</span>
      )}
      <span className="mono" style={{ fontSize: 11, color: t.inkMute, flexShrink: 0, whiteSpace: 'nowrap' }}>{chapters} ch</span>
      <span style={{
        display: 'inline-flex', flexShrink: 0,
        transform: expanded ? 'rotate(90deg)' : 'none', transition: 'transform 150ms',
      }}><BI.ChevronRight s={14} c={t.inkMute} /></span>
    </div>
  );
}

// ChapterCheckRow — indented chapter line revealed under an expanded book.
function ChapterCheckRow({ t, n, checked, done, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12, width: '100%',
      padding: '9px 14px 9px 42px', textAlign: 'left',
      background: t.bgSunken,
      borderBottom: last ? 'none' : `0.5px solid ${t.borderFaint}`,
    }}>
      <CheckBox t={t} checked={checked} />
      <span style={{ flex: 1, minWidth: 0, fontSize: 14, color: t.inkSoft }}>Chapter {n}</span>
      {done && <DoneBadge t={t} />}
    </div>
  );
}

// ──────────────────────────────────────────────────────────
// JobCard — the single active generation job (one job at a time). Title
// lists every book being annotated; progress is measured in annotations
// added, not chapters. Tappable (chevron) to open the per-book detail.
// ──────────────────────────────────────────────────────────
function JobCard({ t, books = [], done = 0, total = 0 }) {
  const value = total ? done / total : 0;
  const title = Array.isArray(books) ? books.join(', ') : books;
  return (
    <div style={{
      background: t.bgRaised,
      border: `0.5px solid ${t.borderFaint}`,
      borderRadius: 16, padding: '14px 15px',
      boxShadow: t.isDark ? '0 1px 2px rgba(0,0,0,0.25)' : '0 1px 2px rgba(40,60,50,0.04)',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 4 }}>
        <span className="bulk-spin" style={{ width: 16, height: 16, flexShrink: 0, display: 'inline-flex' }}>
          <svg width={16} height={16} viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="9" stroke={t.bgSunken} strokeWidth="3" />
            <path d="M12 3a9 9 0 0 1 9 9" stroke={t.accent} strokeWidth="3" strokeLinecap="round" fill="none" />
          </svg>
        </span>
        <span style={{
          flex: 1, minWidth: 0, fontSize: 15, fontWeight: 600, color: t.ink,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{title}</span>
        <BI.ChevronRight s={15} c={t.inkMute} />
      </div>
      <div className="mono" style={{ fontSize: 11.5, color: t.accent, letterSpacing: 0.2, margin: '2px 0 10px', paddingLeft: 26 }}>
        {done} of {total} annotations
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
        <div style={{ flex: 1 }}><ProgressBar t={t} value={value} height={6} /></div>
        <button style={iconGhost(t)} title="Pause"><BI.Pause s={13} c={t.inkSoft} /></button>
      </div>
    </div>
  );
}

function iconGhost(t) {
  return {
    width: 28, height: 28, borderRadius: 8,
    background: t.bgSunken, border: 'none', cursor: 'pointer',
    display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
    flexShrink: 0,
  };
}

// ──────────────────────────────────────────────────────────
// Buttons — primary, ghost, and a full-width destructive button.
// ──────────────────────────────────────────────────────────
function PrimaryBtn({ t, children, icon }) {
  return (
    <button style={{
      width: '100%', padding: '14px 16px', borderRadius: 14,
      background: t.accent, color: t.accentInk, border: 'none',
      fontFamily: 'inherit', fontSize: 15, fontWeight: 600, cursor: 'pointer',
      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
    }}>{icon}{children}</button>
  );
}
function GhostBtn({ t, children }) {
  return (
    <button style={{
      width: '100%', padding: '13px 16px', borderRadius: 14,
      background: 'transparent', color: t.inkSoft,
      border: `1px solid ${t.border}`,
      fontFamily: 'inherit', fontSize: 15, fontWeight: 600, cursor: 'pointer',
    }}>{children}</button>
  );
}

// DangerButton — full-width, red, centered. For "Delete all annotations".
function DangerButton({ t, children, icon }) {
  return (
    <button style={{
      width: '100%', padding: '14px 16px', borderRadius: 14,
      background: failInk(t), color: '#fff', border: 'none',
      fontFamily: 'inherit', fontSize: 15, fontWeight: 600, cursor: 'pointer',
      display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
    }}>{icon}{children}</button>
  );
}

Object.assign(window, {
  BI, failInk, failSoft,
  ProgressRing, ProgressBar, StatusLeaf, ChapterRow, romansChapters,
  JobCard, PrimaryBtn, GhostBtn, DangerButton, iconGhost,
  SettingsScaffold, settingsIconBtn, SGroup, SectionLabel, SRow, Switch,
  CoverageCard, CoverageStat, CheckBox, DoneBadge, BookCheckRow, ChapterCheckRow,
});
