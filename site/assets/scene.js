/* Velora — voice field.
   A WebGL particle surface that moves like a spoken waveform: a quiet field
   that swells into speech-shaped ridges. Purely decorative — the page renders
   completely without it (the .hero-scene aurora is the fallback), so every
   failure path here simply leaves the static design in place.

   Self-hosted three.js module build; no network, no tracking, no storage. */

import * as THREE from "./three.module.min.js";

const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");

/* Resolve a CSS custom property (oklch etc.) to RGB through a 2D canvas,
   because three.js cannot parse modern colour syntax itself. */
const probe = document.createElement("canvas");
probe.width = probe.height = 1;
const probeCtx = probe.getContext("2d", { willReadFrequently: true });

function cssColor(name, fallback) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  if (!value || !probeCtx) return new THREE.Color(fallback);
  probeCtx.clearRect(0, 0, 1, 1);
  probeCtx.fillStyle = "#000";
  probeCtx.fillStyle = value;
  probeCtx.fillRect(0, 0, 1, 1);
  const [r, g, b] = probeCtx.getImageData(0, 0, 1, 1).data;
  return new THREE.Color(r / 255, g / 255, b / 255);
}

const VARIANTS = {
  hero: {
    cols: 236,
    rows: 60,
    width: 17,
    depth: 6.4,
    amp: 1.05,
    pointSize: 3.6,
    camera: { y: 2.05, z: 5.6, tilt: -0.36 },
  },
  page: {
    cols: 210,
    rows: 34,
    width: 19,
    depth: 3.6,
    amp: 0.7,
    pointSize: 3.1,
    camera: { y: 1.55, z: 5.2, tilt: -0.3 },
  },
};

const VERTEX = /* glsl */ `
  uniform float uTime;
  uniform float uAmp;
  uniform float uPointer;
  uniform float uPixelRatio;
  uniform float uPointSize;
  attribute float aSeed;
  varying float vAmp;
  varying float vFade;

  /* Speech reads as bursts, not a steady tone: a slow envelope opens and
     closes over faster carriers, and each column keeps its own phase. */
  float wave(vec2 p, float t) {
    float envelope = 0.55
      + 0.45 * sin(p.x * 0.42 - t * 0.9)
      * sin(p.x * 0.13 + t * 0.31 + sin(t * 0.17) * 2.1);
    envelope = pow(max(envelope, 0.0), 1.6);
    float carrier =
        sin(p.x * 1.7 - t * 2.2)
      + 0.6 * sin(p.x * 3.1 + t * 1.4 + p.y * 1.3)
      + 0.35 * sin(p.x * 5.3 - t * 3.1);
    /* Squared by multiplication: GLSL pow() is undefined for negative bases
       and returns NaN on Apple GPUs, which would blank the whole field. */
    float dx = (p.x - uPointer) * 0.55;
    float focus = 1.0 + 1.35 * exp(-dx * dx);
    return envelope * carrier * focus;
  }

  void main() {
    vec3 p = position;
    /* smoothstep is undefined for edge0 >= edge1 (it breaks on Metal), so
       every falloff here is written as 1.0 - smoothstep(lo, hi, x). */
    float across = 1.0 - smoothstep(0.12, 0.5, abs(uv.y - 0.5));
    float along = smoothstep(0.0, 0.16, uv.x) * (1.0 - smoothstep(0.84, 1.0, uv.x));
    float h = wave(p.xz, uTime + aSeed * 0.35) * uAmp * across * along;
    p.y += h;

    vec4 mv = modelViewMatrix * vec4(p, 1.0);
    gl_Position = projectionMatrix * mv;

    vAmp = clamp(abs(h) * 1.5, 0.0, 1.0);
    vFade = across * along;
    gl_PointSize = uPointSize * uPixelRatio * (0.6 + vAmp * 0.9) * (4.6 / -mv.z);
  }
`;

const FRAGMENT = /* glsl */ `
  uniform vec3 uColorA;
  uniform vec3 uColorB;
  uniform vec3 uColorDim;
  varying float vAmp;
  varying float vFade;

  void main() {
    vec2 c = gl_PointCoord - 0.5;
    float d = length(c);
    float disc = 1.0 - smoothstep(0.18, 0.5, d);
    if (disc < 0.01) discard;
    vec3 color = mix(uColorDim, mix(uColorA, uColorB, vAmp), 0.55 + vAmp * 0.45);
    float alpha = disc * (0.3 + vAmp * 0.6) * vFade;
    gl_FragColor = vec4(color, alpha);
  }
`;

function buildGeometry(spec) {
  const count = spec.cols * spec.rows;
  const positions = new Float32Array(count * 3);
  const uvs = new Float32Array(count * 2);
  const seeds = new Float32Array(count);
  let i = 0;
  for (let r = 0; r < spec.rows; r += 1) {
    for (let c = 0; c < spec.cols; c += 1) {
      const u = c / (spec.cols - 1);
      const v = r / (spec.rows - 1);
      positions[i * 3] = (u - 0.5) * spec.width;
      positions[i * 3 + 1] = 0;
      positions[i * 3 + 2] = (v - 0.5) * spec.depth;
      uvs[i * 2] = u;
      uvs[i * 2 + 1] = v;
      /* Deterministic per-point phase; no Math.random so runs are stable. */
      seeds[i] = Math.abs(Math.sin(c * 12.9898 + r * 78.233));
      i += 1;
    }
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
  geometry.setAttribute("uv", new THREE.BufferAttribute(uvs, 2));
  geometry.setAttribute("aSeed", new THREE.BufferAttribute(seeds, 1));
  return geometry;
}

function mount(host) {
  const spec = VARIANTS[host.dataset.voiceScene] ?? VARIANTS.hero;

  let renderer;
  try {
    renderer = new THREE.WebGLRenderer({
      antialias: false,
      alpha: true,
      powerPreference: "low-power",
      failIfMajorPerformanceCaveat: true,
    });
  } catch (error) {
    return; /* No usable WebGL — the CSS aurora carries the design. */
  }

  const canvas = renderer.domElement;
  host.append(canvas);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(38, 1, 0.1, 40);
  camera.position.set(0, spec.camera.y, spec.camera.z);
  camera.rotation.x = spec.camera.tilt;

  const uniforms = {
    uTime: { value: 0 },
    uAmp: { value: spec.amp },
    uPointer: { value: 0 },
    uPixelRatio: { value: 1 },
    uPointSize: { value: spec.pointSize },
    uColorA: { value: new THREE.Color("#7c6bd6") },
    uColorB: { value: new THREE.Color("#d67c5c") },
    uColorDim: { value: new THREE.Color("#8a86a8") },
  };

  const material = new THREE.ShaderMaterial({
    uniforms,
    vertexShader: VERTEX,
    fragmentShader: FRAGMENT,
    transparent: true,
    depthWrite: false,
  });

  const points = new THREE.Points(buildGeometry(spec), material);
  scene.add(points);

  const syncColors = () => {
    uniforms.uColorA.value.copy(cssColor("--accent", "#7c6bd6"));
    uniforms.uColorB.value.copy(cssColor("--accent-2", "#d67c5c"));
    uniforms.uColorDim.value.copy(cssColor("--ink-faint", "#8a86a8"));
  };
  syncColors();

  const renderOnce = () => renderer.render(scene, camera);

  const resize = () => {
    const width = host.clientWidth || 1;
    const height = host.clientHeight || 1;
    const ratio = Math.min(window.devicePixelRatio || 1, 1.75);
    uniforms.uPixelRatio.value = ratio;
    renderer.setPixelRatio(ratio);
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    if (motionQuery.matches) renderOnce();
  };
  resize();
  new ResizeObserver(resize).observe(host);

  /* Theme changes re-tint the field in place — repaint even while the
     animation loop is paused (reduced motion, hidden tab, out of view). */
  const retint = () => {
    syncColors();
    renderOnce();
  };
  new MutationObserver(retint).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", retint);

  /* Paint one mid-phrase frame immediately: the band is never blank while
     waiting for the visibility observer, and hidden tabs still get a frame. */
  uniforms.uTime.value = 7.4;
  renderOnce();

  /* Reduced motion: that considered frame is the whole show. */
  if (motionQuery.matches) return;

  let pointerTarget = 0;
  window.addEventListener(
    "pointermove",
    (event) => {
      const x = event.clientX / window.innerWidth - 0.5;
      pointerTarget = x * spec.width * 0.7;
    },
    { passive: true }
  );

  let running = false;
  let rafId = 0;
  let last = performance.now();

  const frame = (now) => {
    rafId = window.requestAnimationFrame(frame);
    const dt = Math.min((now - last) / 1000, 0.05);
    last = now;
    uniforms.uTime.value += dt;
    uniforms.uPointer.value += (pointerTarget - uniforms.uPointer.value) * 0.045;
    renderOnce();
  };

  const start = () => {
    if (running) return;
    running = true;
    last = performance.now();
    rafId = window.requestAnimationFrame(frame);
  };

  const stop = () => {
    if (!running) return;
    running = false;
    window.cancelAnimationFrame(rafId);
  };

  /* Only spend frames while the field is actually on screen. */
  const visibility = new IntersectionObserver(
    (entries) => {
      const visible = entries.some((entry) => entry.isIntersecting);
      if (visible && !document.hidden) start();
      else stop();
    },
    { rootMargin: "80px" }
  );
  visibility.observe(host);

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop();
    else if (host.getBoundingClientRect().bottom > 0) start();
  });
}

document.querySelectorAll("[data-voice-scene]").forEach((host) => {
  try {
    mount(host);
  } catch (error) {
    /* Decorative layer only — never let it take the page down. */
  }
});
