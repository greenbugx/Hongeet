function initReveal() {
  const nodes = Array.from(document.querySelectorAll(".reveal"));
  if (!("IntersectionObserver" in window)) {
    nodes.forEach((n) => n.classList.add("is-visible"));
    return;
  }

  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
      });
    },
    { threshold: 0.12 }
  );

  nodes.forEach((n) => io.observe(n));
}

function initHeroThree() {
  if (typeof window.THREE === "undefined") return;
  const canvas = document.getElementById("heroCanvas");
  if (!canvas) return;

  const stage = canvas.parentElement;
  if (!stage) return;

  const prefersReduced = window.matchMedia(
    "(prefers-reduced-motion: reduce)"
  ).matches;

  const renderer = new THREE.WebGLRenderer({
    canvas,
    alpha: true,
    antialias: true,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(40, 1, 0.1, 100);
  camera.position.z = 4.4;

  const group = new THREE.Group();
  scene.add(group);

  const ringMaterial = new THREE.MeshBasicMaterial({
    color: 0xffffff,
    wireframe: true,
    transparent: true,
    opacity: 0.23,
  });

  const ringA = new THREE.Mesh(
    new THREE.TorusGeometry(0.95, 0.025, 14, 140),
    ringMaterial.clone()
  );
  ringA.rotation.x = Math.PI / 2.8;

  const ringB = new THREE.Mesh(
    new THREE.TorusGeometry(1.18, 0.02, 14, 140),
    ringMaterial.clone()
  );
  ringB.material.opacity = 0.16;
  ringB.rotation.y = Math.PI / 3.4;

  const ringC = new THREE.Mesh(
    new THREE.TorusGeometry(1.42, 0.016, 14, 140),
    ringMaterial.clone()
  );
  ringC.material.opacity = 0.12;
  ringC.rotation.x = Math.PI / 5;
  ringC.rotation.y = Math.PI / 6;

  group.add(ringA, ringB, ringC);

  const pointCount = 190;
  const positions = new Float32Array(pointCount * 3);
  for (let i = 0; i < pointCount; i += 1) {
    const r = 1.8 + Math.random() * 0.9;
    const t = Math.random() * Math.PI * 2;
    const p = (Math.random() - 0.5) * Math.PI * 1.2;
    positions[i * 3] = r * Math.cos(t) * Math.cos(p);
    positions[i * 3 + 1] = r * Math.sin(p);
    positions[i * 3 + 2] = r * Math.sin(t) * Math.cos(p);
  }

  const pointsGeometry = new THREE.BufferGeometry();
  pointsGeometry.setAttribute(
    "position",
    new THREE.BufferAttribute(positions, 3)
  );
  const points = new THREE.Points(
    pointsGeometry,
    new THREE.PointsMaterial({
      color: 0xffffff,
      size: 0.017,
      transparent: true,
      opacity: 0.24,
    })
  );
  group.add(points);

  const pointer = { x: 0, y: 0 };

  function onPointerMove(event) {
    const rect = stage.getBoundingClientRect();
    pointer.x = ((event.clientX - rect.left) / rect.width - 0.5) * 2;
    pointer.y = ((event.clientY - rect.top) / rect.height - 0.5) * 2;
  }

  stage.addEventListener("pointermove", onPointerMove);

  function resize() {
    const { width, height } = stage.getBoundingClientRect();
    if (!width || !height) return;
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();

    // Keep rings centered and contained across device sizes/aspect ratios.
    const minSide = Math.min(width, height);
    const fitScale = Math.max(0.72, Math.min(1, (minSide - 28) / 360));
    group.scale.setScalar(fitScale);
  }

  resize();
  window.addEventListener("resize", resize);

  let raf = 0;
  function tick() {
    const speed = prefersReduced ? 0.35 : 1;
    ringA.rotation.z += 0.0028 * speed;
    ringB.rotation.x += 0.0022 * speed;
    ringC.rotation.y -= 0.0019 * speed;
    points.rotation.y += 0.0009 * speed;

    group.rotation.y += (pointer.x * 0.12 - group.rotation.y) * 0.045;
    group.rotation.x += (-pointer.y * 0.1 - group.rotation.x) * 0.045;

    renderer.render(scene, camera);
    raf = requestAnimationFrame(tick);
  }

  tick();

  window.addEventListener("beforeunload", () => {
    cancelAnimationFrame(raf);
    stage.removeEventListener("pointermove", onPointerMove);
    window.removeEventListener("resize", resize);
    renderer.dispose();
  });
}

async function loadVersionInfo() {
  const latestVersion = document.getElementById("latestVersion");
  const apkLink = document.getElementById("apkLink");
  const downloadBtn = document.getElementById("downloadBtn");

  try {
    const res = await fetch("./version.json", { cache: "no-store" });
    if (!res.ok) throw new Error("version.json not found");
    const data = await res.json();

    latestVersion.textContent = data.latest || "v1.3.1+9";

    if (data.apk_url && data.apk_url !== "#") {
      apkLink.href = data.apk_url;
      downloadBtn.href = data.apk_url;
    }
  } catch (_e) {
    latestVersion.textContent = "v1.3.1+9";
  }
}

initReveal();
initHeroThree();
loadVersionInfo();
