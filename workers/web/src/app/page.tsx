const repository = "https://github.com/joeblau/shortreel";

function Mark() {
  return (
    <span className="brand-mark" aria-hidden="true">
      <i />
      <i />
      <i />
    </span>
  );
}

function Arrow() {
  return <span aria-hidden="true">↗</span>;
}

function WorkspacePreview() {
  return (
    <div
      className="workspace"
      role="img"
      aria-label="An illustration of the ShortReel workspace, with two connected iPhones and a slideshow draft workflow."
    >
      <div className="workspace-bar" aria-hidden="true">
        <div className="window-controls">
          <i />
          <i />
          <i />
        </div>
        <span>ShortReel</span>
        <span className="workspace-bar-right">Your creative workspace</span>
      </div>
      <div className="workspace-body" aria-hidden="true">
        <div className="devices">
          <div className="device">
            <div className="device-heading">
              <span>iPhone 01</span>
              <span>•••</span>
            </div>
            <div className="phone phone-home">
              <div className="phone-status">
                <span>9:41</span>
                <span>▰</span>
              </div>
              <div className="home-message">
                <span className="home-spark">✳</span>
                <span>
                  A little space.
                  <br />A fresh start.
                </span>
              </div>
              <div className="phone-dock">
                <span>◎</span>
                <span>▶</span>
                <span>♪</span>
                <span>𝕏</span>
              </div>
            </div>
            <div className="device-status">
              <i /> Connected
            </div>
          </div>
          <div className="device selected-device">
            <div className="device-heading">
              <span>iPhone 02</span>
              <span>•••</span>
            </div>
            <div className="phone phone-creation">
              <div className="phone-status">
                <span>9:41</span>
                <span>▰</span>
              </div>
              <div className="slide-art">
                <span className="slide-number">01 / 05</span>
                <div className="sun" />
                <div className="hill hill-back" />
                <div className="hill hill-front" />
                <p>
                  Take the
                  <br />
                  <em>scenic route.</em>
                </p>
              </div>
              <div className="slide-pagination">
                ● <span>● ● ● ●</span>
              </div>
              <div className="draft-label">Your next story, in slides.</div>
            </div>
            <div className="device-status">
              <i /> Creating a slideshow
            </div>
          </div>
        </div>
        <div className="preview-inspector">
          <div className="preview-tabs">
            <span>Agent</span>
            <span className="active">Stage</span>
            <span>Settings</span>
          </div>
          <div className="inspector-device">
            <i /> iPhone 02
          </div>
          <div className="stage-row">
            <span className="stage-check">✓</span> Clear Home Screen
          </div>
          <div className="stage-row">
            <span className="stage-check">✓</span> Warm Up
          </div>
          <div className="stage-row stage-active">
            <span>03</span> Create Content{" "}
            <span className="stage-arrow">↗</span>
          </div>
          <div className="draft-preview">
            <span className="eyebrow">UP NEXT</span>
            <h3>
              One idea.
              <br />
              Five slides.
            </h3>
            <div>
              <span>Format</span>
              <strong>Slideshow</strong>
            </div>
            <div>
              <span>Destination</span>
              <strong>TikTok</strong>
            </div>
            <div>
              <span>Save as</span>
              <strong>Draft</strong>
            </div>
          </div>
          <p className="review-note">
            Make it yours.
            <br />
            Review before you share.
          </p>
        </div>
      </div>
    </div>
  );
}

export default function Home() {
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <header className="site-header container">
        <a className="brand" href="#" aria-label="ShortReel home">
          <Mark />
          ShortReel
        </a>
        <nav aria-label="Main navigation">
          <a href="#workflow">The workflow</a>
          <a href={repository} className="nav-link">
            View on GitHub <Arrow />
          </a>
        </nav>
      </header>

      <main id="main">
        <section className="hero container" aria-labelledby="hero-title">
          <div className="hero-kicker">
            <span /> MADE FOR YOUR MAC. CONNECTED TO YOUR IPHONES.
          </div>
          <h1 id="hero-title">
            Make room for
            <br />
            your <em>next idea.</em>
          </h1>
          <p className="hero-description">
            Less tapping. More creating. Bring your iPhones into one
            <br className="desktop-break" /> workspace and turn your next idea
            into a content draft.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#workflow">
              Meet your workflow <Arrow />
            </a>
            <a
              className="text-link"
              href={`${repository}/blob/main/apple/README.md`}
            >
              Explore the project <span aria-hidden="true">→</span>
            </a>
          </div>
          <div className="product-preview">
            <WorkspacePreview />
          </div>
          <p className="preview-caption">
            <span>REAL PHONES. ONE WORKSPACE.</span>
            <span>From a clean screen to a fresh draft.</span>
          </p>
        </section>

        <section
          className="workflow-section container"
          id="workflow"
          aria-labelledby="workflow-title"
        >
          <div className="section-heading">
            <span className="eyebrow">A LITTLE LESS BUSYWORK</span>
            <h2 id="workflow-title">Find your creative rhythm.</h2>
            <p>A simple flow, with you in control of what happens next.</p>
          </div>
          <div className="workflow-grid">
            <article>
              <div className="step-heading">
                <span>01</span>
                <span className="step-icon" aria-hidden="true">
                  ⌘
                </span>
              </div>
              <h3>Start with a clean slate.</h3>
              <p>
                Clear the clutter across your Home Screen pages. Keep your
                creative apps close and the rest in App Library.
              </p>
              <span className="step-tag">Prepare your devices</span>
            </article>
            <article>
              <div className="step-heading">
                <span>02</span>
                <span className="step-icon" aria-hidden="true">
                  ↗
                </span>
              </div>
              <h3>Give your idea a direction.</h3>
              <p>
                Choose a slideshow, pick the photos on your phone, and set the
                topic, slide count, caption, and destination.
              </p>
              <span className="step-tag">Configure your content</span>
            </article>
            <article>
              <div className="step-heading">
                <span>03</span>
                <span className="step-icon" aria-hidden="true">
                  ✳
                </span>
              </div>
              <h3>Keep the final say.</h3>
              <p>
                Follow each step from your Mac. Create a draft, review the
                details, and decide when your content is ready to share.
              </p>
              <span className="step-tag">Review your draft</span>
            </article>
          </div>
        </section>

        <section
          className="closing-section container"
          aria-labelledby="closing-title"
        >
          <div>
            <span className="eyebrow">YOUR DEVICES. YOUR DIRECTION.</span>
            <h2 id="closing-title">
              Small screens.
              <br />
              <em>Bigger possibilities.</em>
            </h2>
          </div>
          <div className="closing-copy">
            <p>
              ShortReel brings live iPhone screens, an AI agent, and your
              content workflow together in a native Mac app.
            </p>
            <a className="button button-light" href={repository}>
              Take a closer look <Arrow />
            </a>
          </div>
        </section>
      </main>

      <footer className="site-footer container">
        <a className="brand" href="#">
          <Mark />
          ShortReel
        </a>
        <span>A little more room to create.</span>
        <a href={repository}>
          GitHub <Arrow />
        </a>
      </footer>
    </>
  );
}
