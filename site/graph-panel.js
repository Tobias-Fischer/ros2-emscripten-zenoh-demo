// Drives the "Live ROS graph" panel on the homepage. Polls the local
// zenoh router's REST admin space directly from this page -- no wasm
// involved at all -- to show every topic actually live on the graph right
// now: the two demo cards above, a native `ros2 topic echo`/`rqt_image_view`
// process (see the verification boxes below), or anything else pointed at
// the same router. This is a separate, optional capability from the
// core demos: it needs the router's REST plugin enabled (see the updated
// "Do this first" one-liner), and degrades to a plain "not reachable"
// status if that plugin isn't running rather than affecting anything else
// on the page.
(function () {
  const REST_URL = "http://127.0.0.1:8000/@/**";
  const POLL_MS = 1000;

  // Matches admin-space keys shaped like
  // "@/<router-zid>/router/publisher/0/camera/image/sensor_msgs::msg::dds_::CompressedImage_/RIHS01_<hash>"
  // (or ".../TypeHashNotSupported" from an older RMW that can't compute a
  // real type hash -- see the native-verification box below). Topic names
  // can themselves contain "/", so this relies on regex backtracking to
  // find the *rightmost* "/<pkg>::msg::dds_::<Type>_/" split rather than
  // trying to enumerate path segments by hand.
  const ENTITY_RE =
    /\/router\/(publisher|subscriber)\/\d+\/(.+)\/([A-Za-z0-9_]+)::msg::dds_::([A-Za-z0-9_]+)_\//;

  function setStatus(state, label) {
    const el = document.getElementById("graph-status");
    if (!el) return;
    el.className = "status " + state;
    el.querySelector(".label").textContent = label;
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  function render(topics, sessionCount) {
    const tbody = document.getElementById("graph-tbody");
    const empty = document.getElementById("graph-empty");
    const names = Object.keys(topics).sort();
    if (!names.length) {
      tbody.innerHTML = "";
      empty.style.display = "";
    } else {
      empty.style.display = "none";
      tbody.innerHTML = names
        .map((name) => {
          const t = topics[name];
          return (
            "<tr><td>" + escapeHtml(name) + "</td><td>" + escapeHtml(t.type) +
            "</td><td>" + t.pubs + "</td><td>" + t.subs + "</td></tr>"
          );
        })
        .join("");
    }
    const sessionsEl = document.getElementById("graph-sessions");
    if (sessionsEl) {
      sessionsEl.textContent = sessionCount + (sessionCount === 1 ? " peer" : " peers") + " connected";
    }
  }

  async function poll() {
    let entries;
    try {
      const res = await fetch(REST_URL, { cache: "no-store" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      entries = await res.json();
    } catch (e) {
      setStatus("error", "router not reachable, or its REST plugin isn't enabled -- see the updated setup box above");
      return;
    }

    const topics = {};
    let sessionCount = 0;
    for (const entry of entries) {
      const m = ENTITY_RE.exec(entry.key);
      if (m) {
        const [, role, topic, pkg, typeName] = m;
        const t = (topics[topic] = topics[topic] || { type: pkg + "/" + typeName, pubs: 0, subs: 0 });
        if (role === "publisher") t.pubs++;
        else t.subs++;
        continue;
      }
      // The bare "@/<zid>/router" entry (no further suffix) carries the
      // router's own live session list -- one entry per connected peer
      // (a demo card's wasm session, a native ros2 process, etc), each
      // with its own zenoh session id -- and, since it's already parsed
      // JSON, is a simple direct way to get a "how many peers right now"
      // count without separately walking the per-peer transport keys.
      if (/\/router$/.test(entry.key) && entry.value && Array.isArray(entry.value.sessions)) {
        sessionCount = entry.value.sessions.length;
      }
    }
    setStatus("running", "connected");
    render(topics, sessionCount);
  }

  document.addEventListener("DOMContentLoaded", () => {
    if (!document.getElementById("graph-panel")) return;
    poll();
    setInterval(poll, POLL_MS);
  });
})();
