// Compact in-app presentation of the companion's existing3D scene. The meshes,
// shaders, expression clock, eye motion, and pointer response remain shared.
camera.left = -1.36;
camera.right = 1.36;
camera.top = 1.36;
camera.bottom = -1.36;
camera.zoom = 1;
camera.position.set(0, .2, 8);
camera.lookAt(0, .2, 0);
camera.updateProjectionMatrix();
floor.visible = false;
window.setScreenFacing(0, 0);
const companionSetPaused = window.setPaused;
window.setPaused = value => {
  companionSetPaused(value);
  // Native visibility changes can happen between a canvas resize and the next
  // animation tick. Always leave a complete frame in the presentation buffer.
  renderer.render(scene, camera);
};

const avatarSkins = new Set(['classic', 'blossom', 'snowball']);
const avatarExpressions = new Set(['idle', 'listening', 'transcribing', 'thinking',
  'working', 'speaking', 'completed', 'error', 'needs_input', 'awaiting_approval', 'cancelled']);
let avatarRenderSize = null;

window.picoAvatar = Object.freeze({
  resize(width, height, scale = devicePixelRatio) {
    const edge = Math.max(1, Math.min(Number(width) || 26, Number(height) || 26));
    const pixelRatio = Math.min(2, Math.max(1, Number(scale) || devicePixelRatio || 1));
    petViewport.width = edge;
    petViewport.height = edge;
    if (avatarRenderSize?.edge === edge && avatarRenderSize.pixelRatio === pixelRatio) return;
    // Three's setSize writes canvas.width/height even for the same size. Keep
    // normal native layout passes from clearing and reallocating this canvas.
    renderer.setDrawingBufferSize(edge, edge, pixelRatio);
    avatarRenderSize = {edge, pixelRatio};
    renderer.domElement.style.width = '100%';
    renderer.domElement.style.height = '100%';
    renderer.render(scene, camera);
  },
  pointerAt(x, y) {
    if (!Number.isFinite(x) || !Number.isFinite(y)) return false;
    // AppKit sends a normalized direction, independent of view size or Retina
    // backing pixels. The shared companion API uses its current CSS viewport.
    return window.pointerAt((x + 1) * petViewport.width / 2,
                            (1 - y) * petViewport.height / 2);
  },
  configure({skin = 'snowball', state = 'idle', reducedMotion = false} = {}) {
    window.setSkin(avatarSkins.has(skin) ? skin : 'snowball');
    // In the26pt navigation avatar, express work through the face rather than
    // bringing the companion's full-size keyboard/lamp props into the button.
    window.setPetState('idle');
    window.sprout.setEmotion(avatarExpressions.has(state) ? state : 'idle');
    window.setReducedMotion(reducedMotion);
    renderer.render(scene, camera);
  },
  dispose() {
    window.setPaused(true);
    scene.traverse(node => {
      node.geometry?.dispose();
      for (const material of Array.isArray(node.material) ? node.material : [node.material]) material?.dispose();
    });
    env.texture.dispose();
    renderer.dispose();
  }
});
window.picoAvatar.resize(innerWidth, innerHeight);
window.picoAvatar.configure();
