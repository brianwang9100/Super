// bulk/mockups.jsx — design canvas for the SuperBible *Bulk Annotations*
// MVP (slimmed). Bulk generation is centralized in the Settings →
// Annotations pane. Same glyph vocabulary, three themes, and settings-row
// grammar as the live app.

applyThemeVars(THEMES.light);

function BSwatch({ t, label, sub, children }) {
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg,
      padding: '24px 22px', display: 'flex', flexDirection: 'column',
      color: t.ink, fontFamily: 'Geist, system-ui, sans-serif',
    }}>
      <div className="mono" style={{
        fontSize: 9.5, letterSpacing: 0.7, textTransform: 'uppercase',
        color: t.inkFaint, fontWeight: 500, marginBottom: sub ? 7 : 16,
      }}>{label}</div>
      {sub && <div style={{ fontSize: 13, color: t.inkSoft, marginBottom: 18, maxWidth: 620, lineHeight: 1.5 }}>{sub}</div>}
      <div style={{ flex: 1, display: 'flex', alignItems: 'center' }}>{children}</div>
    </div>
  );
}

// ── Components ────────────────────────────────────────────
function CoverageBitsCard() {
  const t = ANNO_THEMES.light;
  return (
    <BSwatch t={t} label="Coverage synopsis"
      sub="The top of the Annotations pane. A three-level breakdown — books, chapters, verses — of how much of the Bible carries annotations. No note counts.">
      <div style={{ width: '100%', maxWidth: 340 }}>
        <CoverageCard t={t} />
      </div>
    </BSwatch>
  );
}

function JobBitsCard() {
  const t = ANNO_THEMES.light;
  return (
    <BSwatch t={t} label="Active job · one at a time"
      sub="Title lists every book in the run; progress is measured in annotations added, not chapters. Tap to drill into per-book chapter detail; pause at the right.">
      <div style={{ width: '100%', maxWidth: 360 }}>
        <JobCard t={t} books={['Romans', '1 Corinthians', 'Galatians']} done={61} total={420} />
      </div>
    </BSwatch>
  );
}

function ScopeBitsCard() {
  const t = ANNO_THEMES.light;
  return (
    <BSwatch t={t} label="Selection · books expand to chapters"
      sub="A flat book list — no testament grouping. Each book expands to its chapters; fully-annotated books and chapters show a “Done” badge.">
      <div style={{ width: '100%', maxWidth: 360 }}>
        <SGroup t={t} style={{ margin: 0 }}>
          <BookCheckRow t={t} name="Galatians" chapters={6} done />
          <BookCheckRow t={t} name="Romans" chapters={16} checked partial expanded />
          <ChapterCheckRow t={t} n={1} done />
          <ChapterCheckRow t={t} n={2} checked />
          <BookCheckRow t={t} name="John" chapters={21} last />
        </SGroup>
      </div>
    </BSwatch>
  );
}

function ProgressBitsCard() {
  const t = ANNO_THEMES.light;
  return (
    <BSwatch t={t} label="Progress primitives"
      sub="A determinate ring for the headline figure and the four chapter-row states. Failure is the only place a second hue appears.">
      <div style={{ display: 'flex', flexDirection: 'column', gap: 18, width: '100%' }}>
        <div style={{ display: 'flex', gap: 18, alignItems: 'center' }}>
          {[0.15, 0.44, 0.78, 1].map((v) => (
            <ProgressRing key={v} t={t} value={v} size={46} stroke={4}>
              <span className="mono" style={{ fontSize: 11, fontWeight: 600, color: t.ink }}>{Math.round(v * 100)}</span>
            </ProgressRing>
          ))}
        </div>
        <div style={{ maxWidth: 480 }}>
          <ChapterRow t={t} n={5} state="done" count={12} />
          <ChapterRow t={t} n={6} state="failed" />
          <ChapterRow t={t} n={7} state="gen" />
          <ChapterRow t={t} n={8} state="queued" />
        </div>
      </div>
    </BSwatch>
  );
}

// ──────────────────────────────────────────────────────────
function App() {
  return (
    <DesignCanvas>
      {/* 1 · Entry */}
      <DCSection id="entry" title="1 · Entry · Settings"
        subtitle="Bulk generation has one home: Settings → Annotations. The row reads current coverage (“3 books”) so the feature is discoverable from the top level. Everything else matches the live Settings screen.">
        <DCArtboard id="root-light" label="Light" width={336} height={676}>
          <SettingsRootScreen t={ANNO_THEMES.light} />
        </DCArtboard>
        <DCArtboard id="root-sepia" label="Sepia" width={336} height={676}>
          <SettingsRootScreen t={ANNO_THEMES.sepia} />
        </DCArtboard>
        <DCArtboard id="root-dark" label="Dark" width={336} height={676}>
          <SettingsRootScreen t={ANNO_THEMES.dark} />
        </DCArtboard>
      </DCSection>

      {/* 2 · The hub */}
      <DCSection id="hub" title="2 · Annotations pane"
        subtitle="Synopsis at the top (books · chapters · verses), then a single Generate button. Once a job starts, that button is replaced by the one active job. Always ends with the destructive “Delete all annotations”.">
        <DCArtboard id="hub-idle" label="Idle" width={336} height={676}>
          <AnnotationsPaneScreen t={ANNO_THEMES.light} />
        </DCArtboard>
        <DCArtboard id="hub-running" label="Job running" width={336} height={676}>
          <AnnotationsPaneScreen t={ANNO_THEMES.light} running />
        </DCArtboard>
        <DCArtboard id="hub-dark" label="Dark · running" width={336} height={676}>
          <AnnotationsPaneScreen t={ANNO_THEMES.dark} running />
        </DCArtboard>
      </DCSection>

      {/* 3 · Generate */}
      <DCSection id="scope" title="3 · Generate sheet"
        subtitle="A flat list of books — each expands to select individual chapters. Already-annotated books and chapters carry a “Done” badge. The pinned footer keeps a live annotation estimate beside Generate. Confirming dismisses the sheet and starts the one job.">
        <DCArtboard id="scope-light" label="Light" width={336} height={676}>
          <GenerateScopeScreen t={ANNO_THEMES.light} />
        </DCArtboard>
        <DCArtboard id="scope-sepia" label="Sepia" width={336} height={676}>
          <GenerateScopeScreen t={ANNO_THEMES.sepia} />
        </DCArtboard>
        <DCArtboard id="scope-dark" label="Dark" width={336} height={676}>
          <GenerateScopeScreen t={ANNO_THEMES.dark} />
        </DCArtboard>
      </DCSection>

      {/* 4 · Progress */}
      <DCSection id="progress" title="4 · Per-book progress"
        subtitle="Tapping the active job opens its current book. A summary header (ring · annotation count · pause/cancel) sits over the chapter list. Mid-run, and the partial-failure state with per-chapter retry.">
        <DCArtboard id="prog-mid" label="Mid-run" width={336} height={676}>
          <GenerationProgressScreen t={ANNO_THEMES.light} phase="mid" />
        </DCArtboard>
        <DCArtboard id="prog-fail" label="With a failed chapter" width={336} height={676}>
          <GenerationProgressScreen t={ANNO_THEMES.light} phase="failed" />
        </DCArtboard>
        <DCArtboard id="prog-dark" label="Dark · failed" width={336} height={676}>
          <GenerationProgressScreen t={ANNO_THEMES.dark} phase="failed" />
        </DCArtboard>
      </DCSection>

      {/* 8 · Components */}
      <DCSection id="components" title="Components"
        subtitle="The pieces this flow introduces, isolated from screen chrome.">
        <DCArtboard id="cov-bits" label="Coverage" width={460} height={240}>
          <CoverageBitsCard />
        </DCArtboard>
        <DCArtboard id="job-bits" label="Active job" width={460} height={260}>
          <JobBitsCard />
        </DCArtboard>
        <DCArtboard id="scope-bits" label="Selection" width={460} height={340}>
          <ScopeBitsCard />
        </DCArtboard>
        <DCArtboard id="prog-bits" label="Progress primitives" width={560} height={300}>
          <ProgressBitsCard />
        </DCArtboard>
      </DCSection>

      <DCPostIt top={40} left={40} width={262}>
        MVP decisions:
        • One home: Settings → Annotations
        • Synopsis = books · chapters · verses
        • Generate sheet: books expand to chapters; “Done” badges
        • One job at a time; titled by all books; counted in annotations
        • Failures isolate per-chapter → retry, don’t restart
        • Delete-all is a full-width red button
      </DCPostIt>
    </DesignCanvas>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
