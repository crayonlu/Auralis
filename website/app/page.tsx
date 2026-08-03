/* eslint-disable @next/next/no-img-element -- generated local assets are already sized */

export default function Home() {
  return (
    <main className="landing">
      <header className="topbar">
        <a className="brand" href="#" aria-label="Auralis home">
          <img
            className="brand-mark"
            src="/brand-mark.png"
            width="30"
            height="30"
            alt=""
          />
          <span>Auralis</span>
        </a>

        <a
          className="github-link"
          href="https://github.com/crayonlu/Auralis"
          target="_blank"
          rel="noreferrer"
        >
          GitHub <span aria-hidden="true">↗</span>
        </a>
      </header>

      <section className="hero">
        <div className="hero-copy">
          <p className="eyebrow">Auralis for macOS</p>
          <h1>
            Your music.
            <span>At home on Mac.</span>
          </h1>
          <p className="intro">
            A native NetEase Cloud Music player, made quieter, faster, and more
            at home on your desktop.
          </p>

          <div className="actions">
            <a
              className="download"
              href="https://github.com/crayonlu/Auralis/releases/latest"
            >
              Download for macOS
            </a>
            <span>macOS Tahoe 26 or later</span>
          </div>

          <ul className="qualities" aria-label="Product highlights">
            <li>Native SwiftUI</li>
            <li>Synced lyrics</li>
            <li>Smart cache</li>
          </ul>
        </div>

        <div
          className="minimal-player"
          aria-label="Auralis player concept illustration"
        >
          <div className="player-surface">
            <div className="player-topline">
              <div className="playing-state">
                <span className="equalizer" aria-hidden="true">
                  <i />
                  <i />
                  <i />
                </span>
                <span>Now playing</span>
              </div>
              <span className="audio-quality">Lossless</span>
            </div>

            <div className="player-main">
              <div className="album-art">
                <img
                  src="/cover-art.png"
                  alt="Abstract Auralis Sessions cover artwork"
                />
              </div>

              <div className="player-details">
                <div className="track">
                  <p>Still, listening</p>
                  <span>Auralis Sessions</span>
                </div>

                <div className="timeline" aria-hidden="true">
                  <span>
                    <i />
                  </span>
                </div>

                <div className="time" aria-hidden="true">
                  <span>1:24</span>
                  <span>−2:24</span>
                </div>

                <div className="controls">
                  <span aria-hidden="true">‹</span>
                  <span className="pause" role="img" aria-label="Pause">
                    <i />
                    <i />
                  </span>
                  <span aria-hidden="true">›</span>
                </div>
              </div>
            </div>

            <div className="lyric-preview">
              <span>Synced lyric</span>
              <p>Let the quiet find you.</p>
            </div>
          </div>
        </div>
      </section>

      <footer>
        <span>Open source</span>
        <span>Apple silicon + supported Intel Macs</span>
      </footer>
    </main>
  );
}
