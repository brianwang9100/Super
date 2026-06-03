// bulk/screens.jsx — phone surfaces for the *centralized* bulk-annotation
// flow (MVP, slimmed). Everything lives in one Settings pane:
//
//   Settings → Annotations (synopsis + Generate)
//     → Generate sheet (pick books, expand to chapters)
//     → on confirm, the pane shows the single active job
//       → tap the job → per-book chapter progress (mid / failed)
//
// One job at a time. Progress is counted in annotations, never "notes".

// ──────────────────────────────────────────────────────────
// Shared — faint reader peeking behind a sheet/scrim.
// ──────────────────────────────────────────────────────────
function ReaderGhost({ t, opacity = 0.4 }) {
  return (
    <div style={{
      position: 'absolute', top: 44, left: 0, right: 0, bottom: 0,
      opacity, pointerEvents: 'none',
    }}>
      <div style={{ padding: '14px 22px' }}>
        <div className="serif" style={{ fontSize: 22, color: t.ink }}>1 Peter 2</div>
        <p style={{ marginTop: 12, fontSize: 14, lineHeight: 1.6, color: t.inkSoft, textIndent: 14 }}>
          Like newborn infants, long for the pure spiritual milk&hellip;
        </p>
      </div>
    </div>
  );
}

// ══════════════════════════════════════════════════════════
// 1) ENTRY — the real Settings screen, with an "Annotations" row added.
//    Mirrors the live app: search field, grouped cards, no section labels.
// ══════════════════════════════════════════════════════════
function SettingsRootScreen({ t }) {
  return (
    <SettingsScaffold t={t} title="Settings" leading="close">
      <div style={{ padding: '14px 0 8px' }}>
        {/* Search */}
        <div style={{ padding: '0 16px 14px' }}>
          <div style={{
            height: 40, borderRadius: 12, background: t.bgRaised,
            border: `0.5px solid ${t.borderFaint}`,
          }} />
        </div>

        <SGroup t={t}>
          <SRow t={t} icon={<BI.Stack s={20} />} label="Models" value="4 configured" />
          <SRow t={t} icon={<BI.Moon s={20} />} label="Appearance" value="Light" last />
        </SGroup>

        <SGroup t={t}>
          <SRow t={t} icon={<BI.Lines s={20} />} label="Personalization" />
          <SRow t={t} icon={<BI.Branch s={20} />} label="Default Verbosity" value="Simple" />
          <SRow t={t} icon={<BI.Wrench s={20} />} label="Tools" value="3 enabled" />
          <SRow t={t} icon={<BI.Compact s={20} />} label="Compaction" value="Auto" last />
        </SGroup>

        {/* New: Annotations */}
        <SGroup t={t}>
          <SRow t={t} icon={<BI.Bubble s={20} c={t.accent} />} label="Annotations" value="3 books" last />
        </SGroup>

        <SGroup t={t}>
          <SRow t={t} icon={<BI.Database s={20} />} label="Data" value="1 chats" />
          <SRow t={t} icon={<BI.Info s={20} />} label="About" value="v1.0" last />
        </SGroup>
      </div>
    </SettingsScaffold>
  );
}

// ══════════════════════════════════════════════════════════
// 2) THE HUB — Annotations pane. Synopsis (book/chapter/verse) at top, then
//    either a Generate button (idle) or the single active job (running).
//    Always ends with the destructive "Delete all annotations".
// ══════════════════════════════════════════════════════════
function AnnotationsPaneScreen({ t, running = false }) {
  return (
    <SettingsScaffold t={t} title="Annotations" leading="back">
      <div style={{ padding: '14px 0 22px', display: 'flex', flexDirection: 'column', minHeight: '100%' }}>
        <CoverageCard t={t} />

        {running ? (
          <div>
            <SectionLabel t={t}>In progress</SectionLabel>
            <div style={{ padding: '0 16px' }}>
              <JobCard t={t} books={['Romans', '1 Corinthians', 'Galatians']} done={61} total={420} />
            </div>
          </div>
        ) : (
          <div style={{ padding: '0 16px' }}>
            <PrimaryBtn t={t} icon={<AI.Sparkle s={16} c={t.accentInk} />}>Generate annotations</PrimaryBtn>
            <p style={{ fontSize: 12, color: t.inkFaint, textAlign: 'center', margin: '9px 8px 0', lineHeight: 1.45 }}>
              Pick books and chapters to annotate. Runs in the background — keep reading while it works.
            </p>
          </div>
        )}

        <div style={{ flex: 1 }} />

        {/* Destructive — full-width red, centered */}
        <div style={{ padding: '16px 16px 0' }}>
          <DangerButton t={t} icon={<AI.Trash s={15} c="#fff" />}>Delete all annotations</DangerButton>
        </div>
      </div>
    </SettingsScaffold>
  );
}

// ══════════════════════════════════════════════════════════
// 3) GENERATE SHEET — flat book list (no testament grouping). Each book
//    expands to its chapters; already-annotated books/chapters show "Done".
//    Pinned footer carries the live annotation estimate + Generate.
// ══════════════════════════════════════════════════════════
function GenerateScopeScreen({ t }) {
  // Romans is expanded to reveal chapters; some chapters already done.
  const romansCh = [1, 2, 3, 4, 5, 6, 7, 8];
  const romansDone = new Set([1, 2, 3]);
  const books = [
    { name: 'Matthew', ch: 28 },
    { name: 'Mark', ch: 16 },
    { name: 'Luke', ch: 24 },
    { name: 'John', ch: 21, done: true },
    { name: 'Acts', ch: 28 },
  ];
  const footer = (
    <>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, marginBottom: 11 }}>
        <BI.Clock s={13} c={t.inkFaint} />
        <span className="mono" style={{ fontSize: 11.5, color: t.inkFaint, letterSpacing: 0.2 }}>
          2 books · ~210 annotations · est. 2 min
        </span>
      </div>
      <PrimaryBtn t={t} icon={<AI.Sparkle s={16} c={t.accentInk} />}>Generate</PrimaryBtn>
    </>
  );
  return (
    <SettingsScaffold t={t} title="Generate" leading="back" footer={footer}>
      <div style={{ padding: '14px 0 8px' }}>
        <SectionLabel t={t}>Choose what to annotate</SectionLabel>
        <SGroup t={t}>
          {/* Galatians — fully done */}
          <BookCheckRow t={t} name="Galatians" chapters={6} done />

          {/* Romans — expanded, partial */}
          <BookCheckRow t={t} name="Romans" chapters={16} checked partial expanded />
          {romansCh.map((n) => (
            <ChapterCheckRow key={n} t={t} n={n}
              checked={!romansDone.has(n)} done={romansDone.has(n)} />
          ))}
          <div style={{
            padding: '8px 14px 8px 42px', background: t.bgSunken,
            borderBottom: `0.5px solid ${t.borderFaint}`,
            display: 'flex', alignItems: 'center', gap: 6,
          }}>
            <AI.ChevronDown s={12} c={t.inkFaint} />
            <span style={{ fontSize: 12.5, color: t.inkFaint }}>8 more chapters</span>
          </div>

          {books.map((b, i) => (
            <BookCheckRow key={b.name} t={t} name={b.name} chapters={b.ch}
              done={b.done} last={i === books.length - 1} />
          ))}
        </SGroup>
        <div style={{ padding: '0 20px 4px', display: 'flex', alignItems: 'center', gap: 6 }}>
          <AI.ChevronDown s={13} c={t.inkFaint} />
          <span style={{ fontSize: 13, color: t.inkFaint }}>61 more books</span>
        </div>
      </div>
    </SettingsScaffold>
  );
}

// ══════════════════════════════════════════════════════════
// 4) PER-BOOK PROGRESS — drill into the active job's current book. Summary
//    header (ring + annotation count + pause/cancel) over a scrollable
//    chapter list. phase: 'mid' | 'failed'.
// ══════════════════════════════════════════════════════════
function GenerationProgressScreen({ t, phase = 'mid' }) {
  const spec = phase === 'failed' ? { doneCount: 9, failAt: 6 } : { doneCount: 7, failAt: null };
  const rows = romansChapters(spec);
  const failed = rows.filter((r) => r.state === 'failed').length;
  const total = rows.length;
  const value = rows.filter((r) => r.state === 'done' || r.state === 'failed').length / total;
  const annosSoFar = rows.filter((r) => r.state === 'done').reduce((a, r) => a + r.count, 0);
  const annosTotal = rows.reduce((a, r) => a + r.count, 0);

  const header = (
    <div style={{
      padding: '16px 16px', flexShrink: 0,
      borderBottom: `0.5px solid ${t.borderFaint}`,
      display: 'flex', alignItems: 'center', gap: 16,
    }}>
      <ProgressRing t={t} value={value} size={54} stroke={5}>
        <span style={{ fontSize: 13.5, fontWeight: 700, color: t.ink, fontVariantNumeric: 'tabular-nums' }}>
          {Math.round(value * 100)}<span style={{ fontSize: 9, fontWeight: 600 }}>%</span>
        </span>
      </ProgressRing>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 16.5, fontWeight: 600, color: t.ink }}>Romans</div>
        <div className="mono" style={{ fontSize: 11.5, color: t.inkFaint, marginTop: 3, letterSpacing: 0.2 }}>
          {annosSoFar} of ~{annosTotal} annotations
        </div>
      </div>
      <div style={{ display: 'flex', gap: 7, flexShrink: 0 }}>
        <button style={roundBtn(t)}><BI.Pause s={15} c={t.inkSoft} /></button>
        <button style={roundBtn(t)}><AI.Close s={14} c={t.inkSoft} /></button>
      </div>
    </div>
  );

  return (
    <Phone t={t}>
      <StatusBar t={t} />
      <ReaderGhost t={t} opacity={0.14} />
      <div style={{ position: 'absolute', inset: 0, background: t.scrim }} />
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0, top: 30,
        background: t.bg, borderTopLeftRadius: 22, borderTopRightRadius: 22,
        display: 'flex', flexDirection: 'column', overflow: 'hidden',
        boxShadow: t.isDark ? '0 -8px 30px rgba(0,0,0,0.5)' : '0 -8px 30px rgba(40,60,50,0.14)',
      }}>
        {/* Nav header */}
        <div style={{
          display: 'flex', alignItems: 'center', padding: '13px 14px', flexShrink: 0,
        }}>
          <button style={settingsIconBtn(t)}><BI.Back s={17} c={t.ink} /></button>
          <div style={{ flex: 1, textAlign: 'center', fontSize: 16, fontWeight: 600, color: t.ink }}>Generating</div>
          <div style={{ width: 32 }} />
        </div>

        {header}

        {/* Failure banner */}
        {failed > 0 && (
          <div style={{
            flexShrink: 0, margin: '12px 14px 2px', padding: '11px 13px',
            background: failSoft(t), borderRadius: 12,
            display: 'flex', alignItems: 'center', gap: 10,
          }}>
            <BI.Alert s={16} c={failInk(t)} />
            <span style={{ flex: 1, fontSize: 13, color: failInk(t), fontWeight: 500 }}>
              {failed} chapter couldn&rsquo;t be generated
            </span>
            <button style={{
              background: 'transparent', border: 'none', cursor: 'pointer',
              color: failInk(t), fontFamily: 'inherit', fontSize: 12.5, fontWeight: 700,
            }}>Retry all</button>
          </div>
        )}

        {/* Chapter list */}
        <div className="nice-scroll" style={{ flex: 1, overflowY: 'auto', padding: '4px 18px 24px' }}>
          {rows.map((r) => (
            <ChapterRow key={r.n} t={t} n={r.n} state={r.state} count={r.count} />
          ))}
        </div>
      </div>
    </Phone>
  );
}

function roundBtn(t) {
  return {
    width: 32, height: 32, borderRadius: 99, flexShrink: 0,
    background: t.bgSunken, border: 'none', cursor: 'pointer',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
  };
}

Object.assign(window, {
  ReaderGhost, SettingsRootScreen, AnnotationsPaneScreen,
  GenerateScopeScreen, GenerationProgressScreen, roundBtn,
});
